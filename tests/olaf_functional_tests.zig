const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const Environ = std.process.Environ;
const dataset = @import("dataset_download.zig");

/// View of the current process environment, read from the libc `environ`
/// block (the process environment is no longer globally accessible via
/// getEnvMap/getEnvVarOwned in 0.16).
fn currentPosixView() Environ.PosixBlock.View {
    var count: usize = 0;
    while (std.c.environ[count] != null) : (count += 1) {}
    return .{ .slice = @ptrCast(std.c.environ[0..count]) };
}

/// Look up an environment variable in the current process environment.
fn getEnvVar(key: []const u8) ?[:0]const u8 {
    for (currentPosixView().slice) |entry| {
        const span = std.mem.sliceTo(entry, 0);
        if (span.len > key.len and span[key.len] == '=' and std.mem.eql(u8, span[0..key.len], key)) {
            return std.mem.sliceTo(entry + key.len + 1, 0);
        }
    }
    return null;
}

/// Build an Environ.Map seeded from the current process environment (so the
/// spawned olaf — and the ffmpeg it spawns — keep PATH and friends).
fn currentEnvMap(allocator: std.mem.Allocator) !Environ.Map {
    var map = Environ.Map.init(allocator);
    errdefer map.deinit();
    try map.putPosixBlock(currentPosixView());
    return map;
}

// C imports for Olaf core
const c = @cImport({
    @cInclude("olaf_config.h");
    @cInclude("olaf_reader.h");
    @cInclude("olaf_db.h");
    @cInclude("olaf_deque.h");
});

const REF_AUDIO_FILE = "dataset/ref/11266.mp3";

/// Monotonic counter giving each test sandbox a unique suffix (std.time wall-
/// clock helpers were removed in 0.16; a counter is collision-free and needs
/// no io).
var unique_counter: std.atomic.Value(u64) = .init(0);

fn nextUnique() u64 {
    return unique_counter.fetchAdd(1, .monotonic);
}

/// Default config JSON written into the test HOME so the olaf CLI uses
/// our isolated db_folder/cache_folder. Only fields that differ from the
/// built-in defaults need to be set; everything else falls back.
const TEST_CONFIG_JSON =
    \\{
    \\  "db_folder": "~/.olaf/db/",
    \\  "cache_folder": "~/.olaf/cache/"
    \\}
;

// ============================================================================
// Dataset Download - Ensures test audio files are available
// ============================================================================

test "dataset: ensure reference and query files are downloaded" {
    try dataset.ensureDataset(testing.io, testing.allocator, .ref_and_queries);
}

// ============================================================================
// Functional Tests - Testing CLI Commands
// ============================================================================

/// Helper to clean up test database directory
fn cleanupTestDbDir(io: Io, path: []const u8) void {
    Io.Dir.cwd().deleteTree(io, path) catch |err| {
        std.debug.print("Warning: Failed to cleanup test directory {s}: {}\n", .{ path, err });
    };
}

const DEFAULT_OLAF_BIN = "zig-out/bin/olaf";

/// Resolve the olaf CLI path (from `OLAF_BIN` env var, falling back to the
/// default install location) and verify both it and ffmpeg are usable.
/// Returns `error.SkipZigTest` if either is missing — caller should propagate.
///
/// The returned path is owned by the caller iff it's heap-allocated; use the
/// matching `freeOlafBin` to release it safely.
fn resolveOlafBinAndDeps(io: Io, allocator: std.mem.Allocator) ![]const u8 {
    const olaf_bin = if (getEnvVar("OLAF_BIN")) |v|
        try allocator.dupe(u8, v)
    else
        DEFAULT_OLAF_BIN;
    errdefer freeOlafBin(allocator, olaf_bin);

    Io.Dir.cwd().access(io, olaf_bin, .{}) catch {
        std.debug.print("\nSkipping: olaf binary not found at {s} (run `zig build` first)\n", .{olaf_bin});
        return error.SkipZigTest;
    };

    const probe = std.process.run(allocator, io, .{
        .argv = &[_][]const u8{ "ffmpeg", "-version" },
    }) catch {
        std.debug.print("\nSkipping: ffmpeg not available on PATH\n", .{});
        return error.SkipZigTest;
    };
    allocator.free(probe.stdout);
    allocator.free(probe.stderr);

    return olaf_bin;
}

fn freeOlafBin(allocator: std.mem.Allocator, olaf_bin: []const u8) void {
    if (!std.mem.eql(u8, olaf_bin, DEFAULT_OLAF_BIN)) allocator.free(olaf_bin);
}

/// Output of one CLI run; `deinit` frees it.
const Result = struct {
    allocator: std.mem.Allocator,
    stdout: []u8,
    stderr: []u8,
    term: std.process.Child.Term,

    fn deinit(self: Result) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }
};

/// Everything a functional test needs: the olaf binary (skipping the test
/// when it or ffmpeg is missing), an isolated HOME laid out as
/// `tests/test_home_<label>_<n>/.olaf/{db,cache}` with a config pointing
/// there, an environment with HOME overridden, and the canonical path of
/// REF_AUDIO_FILE (empty when the dataset is not downloaded).
const Fixture = struct {
    allocator: std.mem.Allocator,
    io: Io,
    bin: []const u8,
    ref: []u8,
    home: []u8,
    olaf_dir: []u8,
    db_dir: []u8,
    cache_dir: []u8,
    env_map: Environ.Map,

    fn init(allocator: std.mem.Allocator, io: Io, label: []const u8) !Fixture {
        const bin = try resolveOlafBinAndDeps(io, allocator);
        errdefer freeOlafBin(allocator, bin);

        const cwd_path = try Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
        defer allocator.free(cwd_path);

        const home = try std.fmt.allocPrint(allocator, "{s}/tests/test_home_{s}_{d}", .{ cwd_path, label, nextUnique() });
        errdefer allocator.free(home);
        const olaf_dir = try std.fmt.allocPrint(allocator, "{s}/.olaf", .{home});
        errdefer allocator.free(olaf_dir);
        const db_dir = try std.fmt.allocPrint(allocator, "{s}/db", .{olaf_dir});
        errdefer allocator.free(db_dir);
        const cache_dir = try std.fmt.allocPrint(allocator, "{s}/cache", .{olaf_dir});
        errdefer allocator.free(cache_dir);
        try Io.Dir.cwd().createDirPath(io, db_dir);
        try Io.Dir.cwd().createDirPath(io, cache_dir);

        var ref_buf: [std.fs.max_path_bytes]u8 = undefined;
        const ref_n = Io.Dir.cwd().realPathFile(io, REF_AUDIO_FILE, &ref_buf) catch 0;
        const ref = try allocator.dupe(u8, ref_buf[0..ref_n]);
        errdefer allocator.free(ref);

        var env_map = try currentEnvMap(allocator);
        errdefer env_map.deinit();
        try env_map.put("HOME", home);

        var fx = Fixture{
            .allocator = allocator,
            .io = io,
            .bin = bin,
            .ref = ref,
            .home = home,
            .olaf_dir = olaf_dir,
            .db_dir = db_dir,
            .cache_dir = cache_dir,
            .env_map = env_map,
        };
        try fx.writeConfig(TEST_CONFIG_JSON);
        return fx;
    }

    fn deinit(self: *Fixture) void {
        self.env_map.deinit();
        cleanupTestDbDir(self.io, self.home);
        self.allocator.free(self.cache_dir);
        self.allocator.free(self.db_dir);
        self.allocator.free(self.olaf_dir);
        self.allocator.free(self.home);
        self.allocator.free(self.ref);
        freeOlafBin(self.allocator, self.bin);
    }

    /// Replace the fixture's olaf_config.json.
    fn writeConfig(self: *Fixture, config_json: []const u8) !void {
        const config_path = try std.fmt.allocPrint(self.allocator, "{s}/olaf_config.json", .{self.olaf_dir});
        defer self.allocator.free(config_path);
        const f = try Io.Dir.cwd().createFile(self.io, config_path, .{});
        defer f.close(self.io);
        try f.writeStreamingAll(self.io, config_json);
    }

    /// Run `argv` in the fixture's environment and check that it exited
    /// normally with `expected` status (a panic always fails). On a mismatch
    /// the output is printed and error.UnexpectedExitStatus returned.
    fn exec(self: *Fixture, argv: []const []const u8, expected: u8) !Result {
        const r = try std.process.run(self.allocator, self.io, .{ .argv = argv, .environ_map = &self.env_map });
        const result = Result{ .allocator = self.allocator, .stdout = r.stdout, .stderr = r.stderr, .term = r.term };
        const ok_status = switch (r.term) {
            .exited => |code| code == expected,
            else => false,
        };
        if (!ok_status) {
            defer result.deinit();
            const joined = try std.mem.join(self.allocator, " ", argv);
            defer self.allocator.free(joined);
            std.debug.print("\n{s}: expected exit {d}, got {}\nstdout:\n{s}\nstderr:\n{s}\n", .{ joined, expected, r.term, r.stdout, r.stderr });
            return error.UnexpectedExitStatus;
        }
        return result;
    }

    /// Run `olaf <args>`, expecting exit status `expected`.
    fn run(self: *Fixture, args: []const []const u8, expected: u8) !Result {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.allocator);
        try argv.append(self.allocator, self.bin);
        try argv.appendSlice(self.allocator, args);
        return self.exec(argv.items, expected);
    }

    /// Run `olaf <args>`, expecting success, ignoring the output.
    fn ok(self: *Fixture, args: []const []const u8) !void {
        (try self.run(args, 0)).deinit();
    }

    /// Run `olaf <args>`, expecting exit status `expected`, ignoring the output.
    fn expectExit(self: *Fixture, args: []const []const u8, expected: u8) !void {
        (try self.run(args, expected)).deinit();
    }

    /// Run a /bin/sh script in the fixture's environment.
    fn shell(self: *Fixture, script: []const u8, expected: u8) !Result {
        return self.exec(&.{ "/bin/sh", "-c", script }, expected);
    }

    /// `olaf stats`, parsed song count.
    fn songCount(self: *Fixture) !u32 {
        const r = try self.run(&.{"stats"}, 0);
        defer r.deinit();
        return parseSongCount(r.stdout);
    }

    /// Store every file in REF_FILES_FOR_QUERY.
    fn storeAllRefs(self: *Fixture) !void {
        for (REF_FILES_FOR_QUERY) |ref_rel| {
            var ref_buf: [std.fs.max_path_bytes]u8 = undefined;
            const ref_n = try Io.Dir.cwd().realPathFile(self.io, ref_rel, &ref_buf);
            try self.ok(&.{ "store", ref_buf[0..ref_n] });
        }
    }
};

test "functional: store reference audio file" {
    const allocator = testing.allocator;
    const io = testing.io;


    try dataset.ensureDataset(io, allocator, .ref_only);

    var env = try Fixture.init(allocator, io, "store");
    defer env.deinit();

    const ref_abs = env.ref;

    try env.ok(&[_][]const u8{ "store", ref_abs });

    // Verify the audio identifier landed in the LMDB-backed metadata table.
    // The CLI uses the file path as the identifier and `olaf_db_string_hash`
    // to derive the uint32 audio id.
    const c_db_dir = try allocator.dupeZ(u8, env.db_dir);
    defer allocator.free(c_db_dir);
    const db = c.olaf_db_new(c_db_dir.ptr, true);
    try testing.expect(db != null);
    defer c.olaf_db_destroy(db);

    var audio_id: u32 = c.olaf_db_string_hash(ref_abs.ptr, ref_abs.len);
    try testing.expect(c.olaf_db_has_meta_data(db, &audio_id));
}

test "functional: store via CLI and verify via stats command" {
    const allocator = testing.allocator;
    const io = testing.io;


    try dataset.ensureDataset(io, allocator, .ref_only);

    var env = try Fixture.init(allocator, io, "stats");
    defer env.deinit();

    const ref_abs = env.ref;

    try testing.expectEqual(@as(u32, 0), try env.songCount());

    try env.ok(&[_][]const u8{ "store", ref_abs });

    try testing.expectEqual(@as(u32, 1), try env.songCount());
}

const QueryExpectation = struct {
    /// Query audio file under dataset/queries/.
    query_file: []const u8,
    /// Reference file (under dataset/ref/) we expect to be the top match.
    expected_ref: []const u8,
    /// Expected start second of the match in the *reference* track.
    expected_ref_start: f32,
    /// Expected match duration in seconds.
    expected_duration: f32,
    /// Per-entry tolerance (seconds) for ref_start and duration. Most entries
    /// are tight (0.2s); raise it for queries that legitimately drift more.
    tolerance_s: f32 = 0.2,
};

/// Each query is a 20-second cut from the listed reference file, starting at
/// `expected_ref_start`. The 295781 entry is included as an example of the
/// format the user requested even though 295781 is not in REF_FILES — it
/// exercises the no-match branch (tolerance is unused for it).
const QUERY_EXPECTATIONS = [_]QueryExpectation{
    .{ .query_file = "dataset/queries/1051039_34s-54s.mp3", .expected_ref = "dataset/ref/1051039.mp3", .expected_ref_start = 34.0, .expected_duration = 20.0, .tolerance_s = 2.5 },
    .{ .query_file = "dataset/queries/1071559_60s-80s.mp3", .expected_ref = "dataset/ref/1071559.mp3", .expected_ref_start = 60.0, .expected_duration = 20.0, .tolerance_s = 2.5 },
    .{ .query_file = "dataset/queries/1075784_78s-98s.mp3", .expected_ref = "dataset/ref/1075784.mp3", .expected_ref_start = 78.0, .expected_duration = 20.0, .tolerance_s = 1.0 },
    .{ .query_file = "dataset/queries/11266_69s-89s.mp3", .expected_ref = "dataset/ref/11266.mp3", .expected_ref_start = 69.0, .expected_duration = 20.0, .tolerance_s = 3.5 },
    .{ .query_file = "dataset/queries/147199_115s-135s.mp3", .expected_ref = "dataset/ref/147199.mp3", .expected_ref_start = 115.0, .expected_duration = 20.0, .tolerance_s = 1.5 },
    .{ .query_file = "dataset/queries/173050_86s-106s.mp3", .expected_ref = "dataset/ref/173050.mp3", .expected_ref_start = 86.0, .expected_duration = 20.0, .tolerance_s = 2.5 },
    .{ .query_file = "dataset/queries/189211_60s-80s.mp3", .expected_ref = "dataset/ref/189211.mp3", .expected_ref_start = 60.0, .expected_duration = 20.0, .tolerance_s = 1.0 },
    .{ .query_file = "dataset/queries/295781_88s-108s.mp3", .expected_ref = "dataset/ref/295781.mp3", .expected_ref_start = 88.0, .expected_duration = 20.0 },
    .{ .query_file = "dataset/queries/297888_45s-65s.mp3", .expected_ref = "dataset/ref/297888.mp3", .expected_ref_start = 45.0, .expected_duration = 20.0, .tolerance_s = 1.5 },
    .{ .query_file = "dataset/queries/612409_73s-93s.mp3", .expected_ref = "dataset/ref/612409.mp3", .expected_ref_start = 73.0, .expected_duration = 20.0, .tolerance_s = 2.5 },
    .{ .query_file = "dataset/queries/852601_43s-63s.mp3", .expected_ref = "dataset/ref/852601.mp3", .expected_ref_start = 43.0, .expected_duration = 20.0, .tolerance_s = 1.0 },
};

const REF_FILES_FOR_QUERY = [_][]const u8{
    "dataset/ref/1051039.mp3",
    "dataset/ref/1071559.mp3",
    "dataset/ref/1075784.mp3",
    "dataset/ref/11266.mp3",
    "dataset/ref/147199.mp3",
    "dataset/ref/173050.mp3",
    "dataset/ref/189211.mp3",
    "dataset/ref/297888.mp3",
    "dataset/ref/612409.mp3",
    "dataset/ref/852601.mp3",
};

const ParsedResult = struct {
    valid: bool,
    empty_match: bool,
    query: []const u8,
    query_offset: f32,
    match_count: u32,
    query_start: f32,
    query_stop: f32,
    ref_path: []const u8,
    ref_id: []const u8,
    ref_start: f32,
    ref_stop: f32,
};

/// Parse one CSV line from `olaf query` output. Format (11 fields):
/// index, total, query, query_offset, match_count, query_start, query_stop,
/// ref_path, ref_id, ref_start, ref_stop
fn parseResultLine(allocator: std.mem.Allocator, line: []const u8) !?ParsedResult {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);

    // Quote-aware split: olaf quotes path fields containing commas (RFC 4180).
    // Returned slices point into `line`; quoted fields are returned without
    // their quotes (paths in tests never contain a literal '"').
    var i: usize = 0;
    while (i <= line.len) {
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
        if (i < line.len and line[i] == '"') {
            const close = std.mem.indexOfScalarPos(u8, line, i + 1, '"') orelse return null;
            try parts.append(allocator, line[i + 1 .. close]);
            i = (std.mem.indexOfScalarPos(u8, line, close, ',') orelse line.len) + 1;
        } else {
            const end = std.mem.indexOfScalarPos(u8, line, i, ',') orelse line.len;
            try parts.append(allocator, std.mem.trim(u8, line[i..end], " \t\n\r"));
            i = end + 1;
        }
    }
    if (parts.items.len != 11) return null;

    const match_count = std.fmt.parseInt(u32, parts.items[4], 10) catch return null;
    return ParsedResult{
        .valid = true,
        .empty_match = match_count == 0,
        .query = parts.items[2],
        .query_offset = std.fmt.parseFloat(f32, parts.items[3]) catch return null,
        .match_count = match_count,
        .query_start = std.fmt.parseFloat(f32, parts.items[5]) catch return null,
        .query_stop = std.fmt.parseFloat(f32, parts.items[6]) catch return null,
        .ref_path = parts.items[7],
        .ref_id = parts.items[8],
        .ref_start = std.fmt.parseFloat(f32, parts.items[9]) catch return null,
        .ref_stop = std.fmt.parseFloat(f32, parts.items[10]) catch return null,
    };
}

/// Find the first valid result line in `olaf query` output.
fn firstResultLine(allocator: std.mem.Allocator, output: []const u8) !?ParsedResult {
    var lines = std.mem.tokenizeAny(u8, output, "\n");
    while (lines.next()) |line| {
        if (try parseResultLine(allocator, line)) |r| return r;
    }
    return null;
}

test "functional: query against stored references" {
    const allocator = testing.allocator;
    const io = testing.io;


    try dataset.ensureDataset(io, allocator, .ref_and_queries);

    var env = try Fixture.init(allocator, io, "query");
    defer env.deinit();

    try env.storeAllRefs();

    for (QUERY_EXPECTATIONS) |exp| {
        var q_buf: [std.fs.max_path_bytes]u8 = undefined;
        const query_n = try Io.Dir.cwd().realPathFile(io, exp.query_file, &q_buf);
        const query_abs = q_buf[0..query_n];

        const result = try env.run(&[_][]const u8{ "query", query_abs }, 0);
        defer result.deinit();

        const top = (try firstResultLine(allocator, result.stdout)) orelse {
            std.debug.print("\nNo parseable result line for {s}\nstdout:\n{s}\n", .{ exp.query_file, result.stdout });
            return error.OlafQueryNoResult;
        };

        // Whether we expect a match: only when the ref file is in our store set.
        var expect_match = false;
        for (REF_FILES_FOR_QUERY) |ref_rel| {
            if (std.mem.eql(u8, ref_rel, exp.expected_ref)) {
                expect_match = true;
                break;
            }
        }

        if (!expect_match) {
            if (!top.empty_match) {
                std.debug.print("\nUnexpected match for {s}: ref={s} start={d}\n", .{ exp.query_file, top.ref_path, top.ref_start });
                return error.UnexpectedMatch;
            }
            continue;
        }

        if (top.empty_match) {
            std.debug.print("\nExpected match for {s} but got none\nstdout:\n{s}\n", .{ exp.query_file, result.stdout });
            return error.ExpectedMatchMissing;
        }

        // Check the matched reference path corresponds to the expected ref.
        // The CLI records absolute paths, so check by basename.
        const want_base = std.fs.path.basename(exp.expected_ref);
        const got_base = std.fs.path.basename(top.ref_path);
        if (!std.mem.eql(u8, want_base, got_base)) {
            std.debug.print("\nWrong ref for {s}: expected {s}, got {s}\n", .{ exp.query_file, want_base, got_base });
            return error.WrongReferenceMatched;
        }

        if (@abs(top.ref_start - exp.expected_ref_start) > exp.tolerance_s) {
            std.debug.print("\n{s}: ref_start {d:.2} not within {d:.2}s of expected {d:.2}\n", .{ exp.query_file, top.ref_start, exp.tolerance_s, exp.expected_ref_start });
            return error.RefStartOutOfTolerance;
        }

        const actual_duration = top.ref_stop - top.ref_start;
        if (@abs(actual_duration - exp.expected_duration) > exp.tolerance_s) {
            std.debug.print("\n{s}: duration {d:.2} not within {d:.2}s of expected {d:.2}\n", .{ exp.query_file, actual_duration, exp.tolerance_s, exp.expected_duration });
            return error.DurationOutOfTolerance;
        }
    }
}

test "functional: delete removes a stored reference" {
    const allocator = testing.allocator;
    const io = testing.io;


    try dataset.ensureDataset(io, allocator, .ref_and_queries);

    var env = try Fixture.init(allocator, io, "delete");
    defer env.deinit();

    try env.storeAllRefs();

    const total_refs: u32 = @intCast(REF_FILES_FOR_QUERY.len);
    try testing.expectEqual(total_refs, try env.songCount());

    // Pick the last ref — it has a corresponding query file we can re-query
    // to confirm the match disappears after delete.
    const target_ref = REF_FILES_FOR_QUERY[REF_FILES_FOR_QUERY.len - 1];
    const target_query = "dataset/queries/852601_43s-63s.mp3";

    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target_n = try Io.Dir.cwd().realPathFile(io, target_ref, &target_buf);
    const target_abs = target_buf[0..target_n];

    var q_buf: [std.fs.max_path_bytes]u8 = undefined;
    const q_n = try Io.Dir.cwd().realPathFile(io, target_query, &q_buf);
    const q_abs = q_buf[0..q_n];

    // Confirm the query matches before deletion.
    {
        const result = try env.run(&[_][]const u8{ "query", q_abs }, 0);
        defer result.deinit();
        const top = (try firstResultLine(allocator, result.stdout)) orelse return error.OlafQueryNoResult;
        try testing.expect(!top.empty_match);
    }

    // Delete the target ref.
    {
        try env.ok(&[_][]const u8{ "delete", target_abs });
    }

    try testing.expectEqual(total_refs - 1, try env.songCount());

    // The metadata for the deleted ref should be gone from the LMDB store.
    {
        const c_db_dir = try allocator.dupeZ(u8, env.db_dir);
        defer allocator.free(c_db_dir);
        const db = c.olaf_db_new(c_db_dir.ptr, true);
        try testing.expect(db != null);
        defer c.olaf_db_destroy(db);

        var audio_id: u32 = c.olaf_db_string_hash(target_abs.ptr, target_abs.len);
        try testing.expect(!c.olaf_db_has_meta_data(db, &audio_id));
    }

    // Re-querying the same query file should no longer find the deleted ref.
    {
        const result = try env.run(&[_][]const u8{ "query", q_abs }, 0);
        defer result.deinit();

        const top = (try firstResultLine(allocator, result.stdout)) orelse return error.OlafQueryNoResult;
        if (!top.empty_match) {
            const got_base = std.fs.path.basename(top.ref_path);
            const want_base = std.fs.path.basename(target_ref);
            if (std.mem.eql(u8, got_base, want_base)) {
                std.debug.print("\nDeleted ref still matched: {s}\n", .{got_base});
                return error.DeletedRefStillMatches;
            }
        }
    }

    // Re-store the deleted ref and confirm the count returns to the original.
    {
        try env.ok(&[_][]const u8{ "store", target_abs });
    }
    try testing.expectEqual(total_refs, try env.songCount());
}

test "functional: dedup ignores self-matches and surfaces duplicates" {
    const allocator = testing.allocator;
    const io = testing.io;


    try dataset.ensureDataset(io, allocator, .ref_only);

    var env = try Fixture.init(allocator, io, "dedup");
    defer env.deinit();

    // Pick two distinct reference files. Copy the first one to a fresh path
    // (different file name) so the index sees it as a separate audio item;
    // dedup should then report the copy as a duplicate of the original.
    const original = "dataset/ref/11266.mp3";
    const other = "dataset/ref/852601.mp3";

    var orig_buf: [std.fs.max_path_bytes]u8 = undefined;
    const orig_n = try Io.Dir.cwd().realPathFile(io, original, &orig_buf);
    const orig_abs = orig_buf[0..orig_n];

    var other_buf: [std.fs.max_path_bytes]u8 = undefined;
    const other_n = try Io.Dir.cwd().realPathFile(io, other, &other_buf);
    const other_abs = other_buf[0..other_n];

    // Place the duplicate inside the test home so cleanup removes it.
    const dup_path = try std.fmt.allocPrint(allocator, "{s}/dup_11266.mp3", .{env.home});
    defer allocator.free(dup_path);
    try Io.Dir.cwd().copyFile(orig_abs, Io.Dir.cwd(), dup_path, io, .{});
    var dup_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dup_n = try Io.Dir.cwd().realPathFile(io, dup_path, &dup_buf);
    const dup_abs = dup_buf[0..dup_n];

    const result = try env.run(&.{ "dedup", orig_abs, dup_abs, other_abs }, 0);
    defer result.deinit();

    // Expectation: we see at least one non-empty match line where the query
    // is the duplicate and the matched ref is the original (or vice versa),
    // and no result line has a self-match.
    var saw_dup_match = false;
    const dup_base = std.fs.path.basename(dup_path);
    const orig_base = std.fs.path.basename(original);

    var lines = std.mem.tokenizeAny(u8, result.stdout, "\n");
    while (lines.next()) |line| {
        const maybe = parseResultLine(allocator, line) catch continue;
        const parsed = maybe orelse continue;
        if (parsed.empty_match) continue;

        // Self-match check: the result's match_identifier must not equal
        // the hash of the query path. Parse as i64 first to tolerate a
        // signed-printf representation, then truncate to u32.
        const ref_id_signed = std.fmt.parseInt(i64, parsed.ref_id, 10) catch continue;
        const ref_id: u32 = @truncate(@as(u64, @bitCast(ref_id_signed)));
        const self_id: u32 = c.olaf_db_string_hash(parsed.query.ptr, parsed.query.len);

        if (ref_id == self_id) {
            std.debug.print("\nUnexpected self-match in dedup output:\n  query={s}\n  ref={s}\n  ref_id={d}\n  line={s}\n", .{ parsed.query, parsed.ref_path, ref_id, line });
            return error.DedupLeakedSelfMatch;
        }

        // Detect that the duplicate was found.
        const ref_base = std.fs.path.basename(parsed.ref_path);
        const query_base = std.fs.path.basename(parsed.query);
        if (std.mem.eql(u8, query_base, dup_base) and std.mem.eql(u8, ref_base, orig_base)) {
            saw_dup_match = true;
        }
        if (std.mem.eql(u8, query_base, orig_base) and std.mem.eql(u8, ref_base, dup_base)) {
            saw_dup_match = true;
        }
    }

    if (!saw_dup_match) {
        std.debug.print("\nDuplicate match between {s} and {s} not reported.\nstdout:\n{s}\n", .{ original, dup_path, result.stdout });
        return error.DedupMissedDuplicate;
    }
}

test "functional: query --json emits a parseable object with summary + matches" {
    const allocator = testing.allocator;
    const io = testing.io;


    try dataset.ensureDataset(io, allocator, .ref_and_queries);

    var env = try Fixture.init(allocator, io, "json");
    defer env.deinit();

    const ref_rel = "dataset/ref/1051039.mp3";
    const query_rel = "dataset/queries/1051039_34s-54s.mp3";

    var ref_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ref_n = try Io.Dir.cwd().realPathFile(io, ref_rel, &ref_buf);
    const ref_abs = ref_buf[0..ref_n];

    {
        try env.ok(&[_][]const u8{ "store", ref_abs });
    }

    var q_buf: [std.fs.max_path_bytes]u8 = undefined;
    const q_n = try Io.Dir.cwd().realPathFile(io, query_rel, &q_buf);
    const q_abs = q_buf[0..q_n];

    const result = try env.run(&[_][]const u8{ "query", "--format", "json", q_abs }, 0);
    defer result.deinit();

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{}) catch |err| {
        std.debug.print("\nFailed to parse JSON ({}):\n{s}\n", .{ err, result.stdout });
        return error.InvalidJsonOutput;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.JsonRootNotObject;
    const obj = root.object;

    // Required summary fields.
    const required_keys = [_][]const u8{
        "query_index",            "total_queries",
        "query_path",             "query_offset",
        "query_fingerprints",     "query_duration_seconds",
        "fingerprints_per_second", "search_time_seconds",
        "realtime_factor",        "matches",
    };
    for (required_keys) |key| {
        if (obj.get(key) == null) {
            std.debug.print("\nMissing JSON key '{s}' in:\n{s}\n", .{ key, result.stdout });
            return error.MissingJsonKey;
        }
    }

    const matches = obj.get("matches").?;
    if (matches != .array) return error.MatchesNotArray;
    if (matches.array.items.len == 0) {
        std.debug.print("\nExpected at least one match for {s}, got empty array.\n", .{query_rel});
        return error.NoMatchesInJson;
    }

    // Validate the shape of the first match entry.
    const first = matches.array.items[0];
    if (first != .object) return error.MatchEntryNotObject;
    const match_keys = [_][]const u8{
        "match_count",     "query_start",      "query_stop",
        "path",            "match_identifier",
        "reference_start", "reference_stop",
    };
    for (match_keys) |key| {
        if (first.object.get(key) == null) {
            std.debug.print("\nMissing match key '{s}' in:\n{s}\n", .{ key, result.stdout });
            return error.MissingMatchKey;
        }
    }

    // The matched ref path basename should equal the original.
    const ref_path_value = first.object.get("path").?;
    if (ref_path_value != .string) return error.MatchPathNotString;
    const ref_base = std.fs.path.basename(ref_path_value.string);
    const want_base = std.fs.path.basename(ref_rel);
    if (!std.mem.eql(u8, ref_base, want_base)) {
        std.debug.print("\nFirst match path '{s}' (basename '{s}') doesn't match expected '{s}'.\n", .{ ref_path_value.string, ref_base, want_base });
        return error.WrongMatchedRef;
    }
}

test "functional: query --json on empty DB returns empty matches array" {
    const allocator = testing.allocator;
    const io = testing.io;


    try dataset.ensureDataset(io, allocator, .ref_and_queries);

    var env = try Fixture.init(allocator, io, "json_empty");
    defer env.deinit();

    var q_buf: [std.fs.max_path_bytes]u8 = undefined;
    const q_n = try Io.Dir.cwd().realPathFile(io, "dataset/queries/1051039_34s-54s.mp3", &q_buf);
    const q_abs = q_buf[0..q_n];

    const result = try env.run(&[_][]const u8{ "query", "--format", "json", q_abs }, 0);
    defer result.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();

    const matches = parsed.value.object.get("matches") orelse return error.MissingMatchesKey;
    if (matches != .array) return error.MatchesNotArray;
    try testing.expectEqual(@as(usize, 0), matches.array.items.len);
}

/// Parse "Number of songs (#):\t<n>" out of `olaf stats` output.
fn parseSongCount(stats_output: []const u8) !u32 {
    const marker = "Number of songs (#):";
    const idx = std.mem.indexOf(u8, stats_output, marker) orelse return error.SongCountNotFound;
    var rest = stats_output[idx + marker.len ..];
    while (rest.len > 0 and (rest[0] == ' ' or rest[0] == '\t')) rest = rest[1..];
    const end = std.mem.indexOfAny(u8, rest, "\r\n") orelse rest.len;
    const num_str = std.mem.trim(u8, rest[0..end], " \t");
    return try std.fmt.parseInt(u32, num_str, 10);
}

test "functional: config validation" {
    // Test that configuration can be loaded and validated
    const config = c.olaf_config_default();
    defer c.olaf_config_destroy(config);

    try testing.expect(config.*.audioSampleRate > 0);
    try testing.expect(config.*.audioBlockSize > 0);
    try testing.expect(config.*.audioStepSize > 0);
    try testing.expect(config.*.audioStepSize <= config.*.audioBlockSize);
}

test "functional: usage errors exit with status 2" {
    const allocator = testing.allocator;
    const io = testing.io;


    try dataset.ensureDataset(io, allocator, .ref_only);

    var env = try Fixture.init(allocator, io, "usage");
    defer env.deinit();

    const ref_abs = env.ref;

    try env.expectExit(&.{"nosuchcmd"}, 2);
    try env.expectExit(&.{"query"}, 2);
    try env.expectExit(&.{ "query", "--format", "xml", ref_abs }, 2);
    try env.expectExit(&.{ "query", "--threads" }, 2);
    try env.expectExit(&.{ "query", "--threads", "abc", ref_abs }, 2);
    try env.expectExit(&.{ "query", "--threads", "0", ref_abs }, 2);
    try env.expectExit(&.{ "store", "--with-ids", ref_abs }, 2);
    try env.expectExit(&.{ "store", "--with-ids", ref_abs, "--threads" }, 2);
    try env.expectExit(&.{"--help"}, 0);
}

/// Store REF_AUDIO_FILE, run `query --fragmented` on it, and check that each
/// matched fragment reports its offset: expected offsets must all appear, all
/// offsets are multiples of `step`, and for strong matches
/// ref_start ~= query_offset + query_start.
fn expectFragmentOffsets(env: *Fixture, ref_abs: []const u8, step: f32, expected: []const f32) !void {
    const allocator = env.allocator;
    try env.ok(&.{ "store", ref_abs });

    const result = try env.run(&.{ "query", "--fragmented", ref_abs }, 0);
    defer result.deinit();

    var seen: std.ArrayList(f32) = .empty;
    defer seen.deinit(allocator);

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const r = (try parseResultLine(allocator, line)) orelse continue;
        if (r.empty_match) continue;
        try testing.expectEqual(@as(f32, 0), @mod(r.query_offset, step));
        // Weak secondary matches against repeated passages elsewhere in the
        // same song are legitimate; only the strong self-match must align.
        if (r.match_count < 50) continue;
        try testing.expect(@abs(r.ref_start - (r.query_offset + r.query_start)) < 2.0);
        try seen.append(allocator, r.query_offset);
    }
    for (expected) |want| {
        try testing.expect(std.mem.indexOfScalar(f32, seen.items, want) != null);
    }
}

test "functional: query --fragmented reports fragment offsets" {
    const allocator = testing.allocator;
    const io = testing.io;

    try dataset.ensureDataset(io, allocator, .ref_only);

    var env = try Fixture.init(allocator, io, "fragmented");
    defer env.deinit();

    const ref_abs = env.ref;

    // REF_AUDIO_FILE is ~98s: default 30s fragments start at 0, 30, 60, 90.
    try expectFragmentOffsets(&env, ref_abs, 30, &.{ 0, 30, 60 });

    const json_result = try env.run(&.{ "query", "--fragmented", "--format", "json", ref_abs }, 0);
    defer json_result.deinit();
    try testing.expect(std.mem.indexOf(u8, json_result.stdout, "\"query_offset\": 30.000") != null);
}

test "functional: query --fragmented honours fragment_duration_in_seconds" {
    const allocator = testing.allocator;
    const io = testing.io;

    try dataset.ensureDataset(io, allocator, .ref_only);

    var ref_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ref_n = try Io.Dir.cwd().realPathFile(io, REF_AUDIO_FILE, &ref_buf);
    const ref_abs = ref_buf[0..ref_n];

    {
        var env = try Fixture.init(allocator, io, "frag20");
        defer env.deinit();
        try env.writeConfig(
            \\{"db_folder": "~/.olaf/db/", "cache_folder": "~/.olaf/cache/", "fragment_duration_in_seconds": 20}
        );
        try expectFragmentOffsets(&env, ref_abs, 20, &.{ 0, 20, 40 });
    }
    {
        // 0 used to spin forever (fragment_start never advances); now a config error.
        var env = try Fixture.init(allocator, io, "frag0");
        defer env.deinit();
        try env.writeConfig(
            \\{"db_folder": "~/.olaf/db/", "cache_folder": "~/.olaf/cache/", "fragment_duration_in_seconds": 0}
        );
        try env.expectExit(&.{ "query", "--fragmented", ref_abs }, 1);
    }
}

/// Count files in `dir` whose name ends with `suffix`.
fn countFilesWithSuffix(io: Io, dir_path: []const u8, suffix: []const u8) !usize {
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var n: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, suffix)) n += 1;
    }
    return n;
}

/// Write a file with an audio extension but non-audio content, so ffmpeg fails.
fn writeBadAudioFile(env: *Fixture) ![]u8 {
    const path = try std.fmt.allocPrint(env.allocator, "{s}/bad.mp3", .{env.home});
    errdefer env.allocator.free(path);
    const f = try Io.Dir.cwd().createFile(env.io, path, .{});
    defer f.close(env.io);
    try f.writeStreamingAll(env.io, "this is not audio");
    return path;
}

test "functional: cache leaves no partial files when a file fails" {
    const allocator = testing.allocator;
    const io = testing.io;

    try dataset.ensureDataset(io, allocator, .ref_only);

    var env = try Fixture.init(allocator, io, "cache");
    defer env.deinit();

    const bad = try writeBadAudioFile(&env);
    defer allocator.free(bad);

    try env.expectExit(&.{ "cache", bad }, 1);
    try testing.expectEqual(@as(usize, 0), try countFilesWithSuffix(io, env.cache_dir, ".tdb"));
    try testing.expectEqual(@as(usize, 0), try countFilesWithSuffix(io, env.cache_dir, ".meta"));

    var ref_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ref_n = try Io.Dir.cwd().realPathFile(io, REF_AUDIO_FILE, &ref_buf);
    try env.ok(&.{ "cache", ref_buf[0..ref_n] });
    try testing.expectEqual(@as(usize, 1), try countFilesWithSuffix(io, env.cache_dir, ".tdb"));
    try testing.expectEqual(@as(usize, 1), try countFilesWithSuffix(io, env.cache_dir, ".meta"));
    try testing.expectEqual(@as(usize, 0), try countFilesWithSuffix(io, env.cache_dir, ".tmp"));
}

test "functional: store continues past a bad file (serial and parallel)" {
    const allocator = testing.allocator;
    const io = testing.io;

    try dataset.ensureDataset(io, allocator, .ref_only);

    var ref_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ref_n = try Io.Dir.cwd().realPathFile(io, REF_AUDIO_FILE, &ref_buf);
    const ref_abs = ref_buf[0..ref_n];

    for ([_][]const u8{ "1", "2" }) |threads| {
        var env = try Fixture.init(allocator, io, "store_bad");
        defer env.deinit();

        const bad = try writeBadAudioFile(&env);
        defer allocator.free(bad);

        // The bad file comes first: a serial run used to abort right there.
        try env.expectExit(&.{ "store", "--threads", threads, bad, ref_abs }, 1);
        try testing.expectEqual(@as(u32, 1), try env.songCount());
    }
}

test "functional: db_folder without trailing slash still reports stats" {
    const allocator = testing.allocator;
    const io = testing.io;

    try dataset.ensureDataset(io, allocator, .ref_only);

    var env = try Fixture.init(allocator, io, "noslash");
    defer env.deinit();
    try env.writeConfig(
        \\{"db_folder": "~/.olaf/db", "cache_folder": "~/.olaf/cache/"}
    );

    var ref_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ref_n = try Io.Dir.cwd().realPathFile(io, REF_AUDIO_FILE, &ref_buf);
    try env.ok(&.{ "store", ref_buf[0..ref_n] });

    // Used to report 0 songs: stats looked for "<db>data.mdb".
    try testing.expectEqual(@as(u32, 1), try env.songCount());
}

test "functional: store skips already indexed files unless forced" {
    const allocator = testing.allocator;
    const io = testing.io;

    try dataset.ensureDataset(io, allocator, .ref_only);

    var env = try Fixture.init(allocator, io, "skipdup");
    defer env.deinit();
    const ref_abs = env.ref;

    try env.ok(&.{ "store", ref_abs });

    {
        const again = try env.run(&.{ "store", "--format", "csv", ref_abs }, 0);
        defer again.deinit();
        try testing.expect(std.mem.indexOf(u8, again.stderr, "skip,,,") != null);
        try testing.expect(std.mem.indexOf(u8, again.stderr, "store,") == null);
    }
    {
        const forced = try env.run(&.{ "store", "-f", "--format", "csv", ref_abs }, 0);
        defer forced.deinit();
        try testing.expect(std.mem.indexOf(u8, forced.stderr, "store,1,1,") != null);
    }
    try testing.expectEqual(@as(u32, 1), try env.songCount());

    // skip_duplicates: false restores the old always-store behaviour.
    try env.writeConfig(
        \\{"db_folder": "~/.olaf/db/", "cache_folder": "~/.olaf/cache/", "skip_duplicates": false}
    );
    const unskipped = try env.run(&.{ "store", "--format", "csv", ref_abs }, 0);
    defer unskipped.deinit();
    try testing.expect(std.mem.indexOf(u8, unskipped.stderr, "store,1,1,") != null);
}

test "functional: output redirected to a file keeps every line" {
    const allocator = testing.allocator;
    const io = testing.io;


    var env = try Fixture.init(allocator, io, "redirect");
    defer env.deinit();

    const out_path = try std.fmt.allocPrint(allocator, "{s}/help.txt", .{env.home});
    defer allocator.free(out_path);
    // `--help` is printed with many separate print() calls; pipes (as used by
    // Fixture.run) hide the bug, a regular file shows it.
    const cmd = try std.fmt.allocPrint(allocator, "'{s}' --help > '{s}'", .{ env.bin, out_path });
    defer allocator.free(cmd);
    (try env.shell(cmd, 0)).deinit();

    const content = try Io.Dir.cwd().readFileAlloc(io, out_path, allocator, .limited(1024 * 1024));
    defer allocator.free(content);
    // First and last lines of the help must both survive.
    try testing.expect(std.mem.startsWith(u8, content, "Olaf"));
    try testing.expect(std.mem.indexOf(u8, content, "The following commands are valid") != null);
    try testing.expect(std.mem.indexOf(u8, content, "olaf dedup") != null);
}

test "functional: cache then store_cached on a fresh database" {
    const allocator = testing.allocator;
    const io = testing.io;

    try dataset.ensureDataset(io, allocator, .ref_only);

    var env = try Fixture.init(allocator, io, "store_cached");
    defer env.deinit();

    var ref_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ref_n = try Io.Dir.cwd().realPathFile(io, REF_AUDIO_FILE, &ref_buf);
    try env.ok(&.{ "cache", ref_buf[0..ref_n] });

    {
        // Used to exit() in the C core: the duplicate check opened a
        // read-only env on a database that did not exist yet.
        const r = try env.run(&.{"store_cached"}, 0);
        defer r.deinit();
        try testing.expect(std.mem.indexOf(u8, r.stdout, "1/1, ") != null);
        try testing.expect(std.mem.indexOf(u8, r.stdout, "stored from cache") != null);
        // olaf_has used to print this header + a row per file to stdout.
        try testing.expect(std.mem.indexOf(u8, r.stdout, "internal identifier") == null);
    }
    try testing.expectEqual(@as(u32, 1), try env.songCount());
    {
        const r = try env.run(&.{"store_cached"}, 0);
        defer r.deinit();
        try testing.expect(std.mem.indexOf(u8, r.stdout, "SKIPPED: already indexed") != null);
        try testing.expect(std.mem.indexOf(u8, r.stdout, "Stored 0 cache file(s), skipped 1 already indexed, 0 failed") != null);
    }
    {
        const r = try env.run(&.{ "store_cached", "-f" }, 0);
        defer r.deinit();
        try testing.expect(std.mem.indexOf(u8, r.stdout, "Stored 1 cache file(s)") != null);
    }
}

fn copyFileTo(io: Io, allocator: std.mem.Allocator, src: []const u8, dst: []const u8) !void {
    const data = try Io.Dir.cwd().readFileAlloc(io, src, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(data);
    if (std.fs.path.dirname(dst)) |parent| try Io.Dir.cwd().createDirPath(io, parent);
    const f = try Io.Dir.cwd().createFile(io, dst, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, data);
}

test "functional: to_raw / to_wav refuse colliding or in-place outputs" {
    const allocator = testing.allocator;
    const io = testing.io;

    try dataset.ensureDataset(io, allocator, .ref_only);

    var env = try Fixture.init(allocator, io, "transcode");
    defer env.deinit();

    const a = try std.fmt.allocPrint(allocator, "{s}/a/song.mp3", .{env.home});
    defer allocator.free(a);
    const b = try std.fmt.allocPrint(allocator, "{s}/b/song.mp3", .{env.home});
    defer allocator.free(b);
    const in_wav = try std.fmt.allocPrint(allocator, "{s}/a/in.wav", .{env.home});
    defer allocator.free(in_wav);
    try copyFileTo(io, allocator, REF_AUDIO_FILE, a);
    try copyFileTo(io, allocator, "dataset/ref/173050.mp3", b);
    try copyFileTo(io, allocator, REF_AUDIO_FILE, in_wav);

    // to_raw writes olaf_audio_song.raw into the cwd for both inputs: the
    // second used to be reported as converted while silently reusing the first.
    const script = try std.fmt.allocPrint(allocator, "cd '{s}' && '{s}' to_raw '{s}' '{s}'", .{ env.home, env.bin, a, b });
    defer allocator.free(script);
    (try env.shell(script, 1)).deinit();
    try testing.expect(try fileExists(io, allocator, env.home, "olaf_audio_song.raw"));
    try testing.expect(!try fileExists(io, allocator, env.home, "olaf_audio_song.raw.part"));

    // to_wav on a .wav would target its own input: used to be a silent no-op.
    const size_before = (try Io.Dir.cwd().statFile(io, in_wav, .{})).size;
    try env.expectExit(&.{ "to_wav", in_wav }, 1);
    try testing.expectEqual(size_before, (try Io.Dir.cwd().statFile(io, in_wav, .{})).size);
}

test "functional: relative, absolute and symlinked paths share one identifier" {
    const allocator = testing.allocator;
    const io = testing.io;

    try dataset.ensureDataset(io, allocator, .ref_only);

    var env = try Fixture.init(allocator, io, "canonical");
    defer env.deinit();

    const ref_abs = env.ref;
    const ref_dir = std.fs.path.dirname(ref_abs).?;
    const repo_dir = std.fs.path.dirname(std.fs.path.dirname(ref_dir).?).?;

    try env.ok(&.{ "store", ref_abs });

    // Same file, spelled relative to the cwd and through a symlinked dir:
    // both used to get a different identifier and be indexed again.
    const scripts = [_][]const u8{
        try std.fmt.allocPrint(allocator, "cd '{s}' && '{s}' store --format csv ./dataset/ref/../ref/11266.mp3", .{ repo_dir, env.bin }),
        try std.fmt.allocPrint(allocator, "ln -s '{s}' '{s}/linked' && '{s}' store --format csv '{s}/linked/11266.mp3'", .{ ref_dir, env.home, env.bin, env.home }),
    };
    defer for (scripts) |sc| allocator.free(sc);

    for (scripts) |script| {
        const r = try env.shell(script, 0);
        defer r.deinit();
        try testing.expect(std.mem.indexOf(u8, r.stderr, "skip,,,") != null);
    }
    try testing.expectEqual(@as(u32, 1), try env.songCount());
}

test "functional: directory arguments are processed in sorted order" {
    const allocator = testing.allocator;
    const io = testing.io;


    var env = try Fixture.init(allocator, io, "order");
    defer env.deinit();

    // Created out of order; APFS/ext4 readdir order is not alphabetical
    // (APFS returns a b c f d e for these names).
    const dir = try std.fmt.allocPrint(allocator, "{s}/music", .{env.home});
    defer allocator.free(dir);
    const names = [_][]const u8{ "d.mp3", "b.mp3", "f.mp3", "a.mp3", "e.mp3", "c.mp3" };
    for (names) |n| try touchFile(io, allocator, dir, n);

    // Empty files fail in ffmpeg; with the continue-on-error policy each
    // failure is logged in processing order, which is all this test needs.
    const r = try env.run(&.{ "store", dir }, 1);
    defer r.deinit();

    var last: usize = 0;
    for ([_][]const u8{ "a.mp3", "b.mp3", "c.mp3", "d.mp3", "e.mp3", "f.mp3" }) |n| {
        const needle = try std.fmt.allocPrint(allocator, "Failed to process {s}/{s}", .{ dir, n });
        defer allocator.free(needle);
        const pos = std.mem.indexOf(u8, r.stderr, needle) orelse return error.MissingFile;
        try testing.expect(pos >= last);
        last = pos;
    }
}

test "functional: .txt lists skip bad lines instead of aborting" {
    const allocator = testing.allocator;
    const io = testing.io;

    try dataset.ensureDataset(io, allocator, .ref_only);

    var env = try Fixture.init(allocator, io, "txtlist");
    defer env.deinit();

    var ref_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ref_n = try Io.Dir.cwd().realPathFile(io, REF_AUDIO_FILE, &ref_buf);
    try touchFile(io, allocator, env.home, "notes.doc");

    const list_path = try std.fmt.allocPrint(allocator, "{s}/list.txt", .{env.home});
    defer allocator.free(list_path);
    const list = try std.fmt.allocPrint(allocator, "{s}\n# a comment\n\n/nonexistent/x.mp3\n{s}/notes.doc\n", .{ ref_buf[0..ref_n], env.home });
    defer allocator.free(list);
    {
        const f = try Io.Dir.cwd().createFile(io, list_path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, list);
    }

    const r = try env.run(&.{ "store", list_path }, 0);
    defer r.deinit();
    try testing.expect(std.mem.indexOf(u8, r.stderr, "list.txt:4: could not find") != null);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "list.txt:5: not an audio file") != null);
    try testing.expectEqual(@as(u32, 1), try env.songCount());
}

test "functional: query CSV quotes paths with commas" {
    const allocator = testing.allocator;
    const io = testing.io;

    try dataset.ensureDataset(io, allocator, .ref_only);

    var env = try Fixture.init(allocator, io, "comma");
    defer env.deinit();

    const song = try std.fmt.allocPrint(allocator, "{s}/Crosby, Stills.mp3", .{env.home});
    defer allocator.free(song);
    try copyFileTo(io, allocator, REF_AUDIO_FILE, song);

    var song_buf: [std.fs.max_path_bytes]u8 = undefined;
    const song_n = try Io.Dir.cwd().realPathFile(io, song, &song_buf);
    const song_abs = song_buf[0..song_n];

    try env.ok(&.{ "store", song_abs });

    const r = try env.run(&.{ "query", song_abs }, 0);
    defer r.deinit();

    const quoted = try std.fmt.allocPrint(allocator, "\"{s}\"", .{song_abs});
    defer allocator.free(quoted);
    try testing.expect(std.mem.indexOf(u8, r.stdout, quoted) != null);
    // Strict RFC 4180 parsers need the quote right after the separator: the
    // reference path used to follow ", " (pandas/Excel split it).
    const ref_field = try std.fmt.allocPrint(allocator, ",\"{s}\", ", .{song_abs});
    defer allocator.free(ref_field);
    try testing.expect(std.mem.indexOf(u8, r.stdout, ref_field) != null);

    const row = (try firstResultLine(allocator, r.stdout)) orelse return error.NoResultLine;
    try testing.expect(!row.empty_match);
    try testing.expectEqualStrings(song_abs, row.query);
    try testing.expectEqualStrings(song_abs, row.ref_path);
}

test "functional: microphone reports a capture failure" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = testing.io;


    var env = try Fixture.init(allocator, io, "microphone");
    defer env.deinit();
    // ffmpeg fails immediately on an unknown input format: no real
    // microphone is needed. This used to end silently with exit status 0.
    try env.writeConfig(
        \\{"db_folder": "~/.olaf/db/", "cache_folder": "~/.olaf/cache/", "microphone_input_format": "no_such_format"}
    );

    const r = try env.run(&.{"microphone"}, 1);
    defer r.deinit();
    try testing.expect(std.mem.indexOf(u8, r.stderr, "microphone capture failed") != null);
    // ffmpeg's own reason is no longer hidden by -loglevel panic.
    try testing.expect(std.mem.indexOf(u8, r.stderr, "no_such_format") != null);
}

test "functional: parallel store matches serial store" {
    const allocator = testing.allocator;
    const io = testing.io;

    try dataset.ensureDataset(io, allocator, .ref_and_queries);

    var ref_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ref_dir_n = try Io.Dir.cwd().realPathFile(io, "dataset/ref", &ref_dir_buf);
    var q_buf: [std.fs.max_path_bytes]u8 = undefined;
    const q_n = try Io.Dir.cwd().realPathFile(io, "dataset/queries/612409_73s-93s.mp3", &q_buf);

    var stats_out: [2][]u8 = undefined;
    var top_ids: [2][]u8 = undefined;
    for ([_][]const u8{ "1", "4" }, 0..) |threads, i| {
        var env = try Fixture.init(allocator, io, "par_store");
        defer env.deinit();

        try env.ok(&.{ "store", "--threads", threads, ref_dir_buf[0..ref_dir_n] });

        const stats = try env.run(&.{"stats"}, 0);
        allocator.free(stats.stderr);
        stats_out[i] = stats.stdout;

        const q = try env.run(&.{ "query", q_buf[0..q_n] }, 0);
        defer q.deinit();
        const row = (try firstResultLine(allocator, q.stdout)) orelse return error.NoResultLine;
        try testing.expect(!row.empty_match);
        top_ids[i] = try allocator.dupe(u8, row.ref_id);
    }
    defer for (stats_out) |o| allocator.free(o);
    defer for (top_ids) |t| allocator.free(t);

    try testing.expectEqualStrings(stats_out[0], stats_out[1]);
    try testing.expectEqualStrings(top_ids[0], top_ids[1]);
}

// ============================================================================
// Output snapshot: locks the exact CLI output (store/query in every format,
// skip records, fragmented and comma paths, stats) so refactors can prove
// they are byte-for-byte behaviour preserving. Regenerate deliberately with
// OLAF_UPDATE_GOLDEN=1 zig build test.
// ============================================================================

const GOLDEN_SNAPSHOT = "tests/golden/output_snapshot.txt";

/// Where the snapshot was generated. Fingerprints depend on the audio
/// decoder (ffmpeg version) and on floating point details of the platform,
/// so a byte-exact snapshot only compares within one environment; the golden
/// file's first line records it and other environments skip the test.
fn snapshotEnvironment(allocator: std.mem.Allocator, io: Io) ![]u8 {
    const r = try std.process.run(allocator, io, .{ .argv = &.{ "ffmpeg", "-version" } });
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);
    const first_line = std.mem.sliceTo(r.stdout, '\n');
    var words = std.mem.tokenizeScalar(u8, first_line, ' ');
    _ = words.next(); // "ffmpeg"
    _ = words.next(); // "version"
    const version = words.next() orelse "unknown";
    const builtin = @import("builtin");
    return std.fmt.allocPrint(allocator, "# environment: {s}-{s} ffmpeg {s}", .{ @tagName(builtin.cpu.arch), @tagName(builtin.os.tag), version });
}

/// Replace `"key":<number>` / `"key": <number>` values with <T>.
fn maskJsonNumber(allocator: std.mem.Allocator, line: []const u8, key: []const u8) ![]u8 {
    const needle = try std.fmt.allocPrint(allocator, "\"{s}\":", .{key});
    defer allocator.free(needle);
    const at = std.mem.indexOf(u8, line, needle) orelse return allocator.dupe(u8, line);
    var start = at + needle.len;
    while (start < line.len and line[start] == ' ') start += 1;
    var end = start;
    while (end < line.len and line[end] != ',' and line[end] != '}' and line[end] != '\n') end += 1;
    return std.fmt.allocPrint(allocator, "{s}<T>{s}", .{ line[0..start], line[end..] });
}

/// Mask machine-dependent parts of one output line: absolute path prefixes
/// and timing values (cpu time, realtime factor, search time).
fn maskVolatile(allocator: std.mem.Allocator, raw: []const u8, repo: []const u8, home: []const u8) ![]u8 {
    var line = try std.mem.replaceOwned(u8, allocator, raw, home, "<HOME>");
    {
        const next = try std.mem.replaceOwned(u8, allocator, line, repo, "<REPO>");
        allocator.free(line);
        line = next;
    }
    for ([_][]const u8{ "cpu_seconds", "realtime_factor", "search_time_seconds" }) |key| {
        const next = try maskJsonNumber(allocator, line, key);
        allocator.free(line);
        line = next;
    }
    if (std.mem.startsWith(u8, line, "store,")) {
        // ...,audio_seconds,cpu_seconds,fingerprints_per_second,realtime_factor
        const c1 = std.mem.lastIndexOfScalar(u8, line, ',').?;
        const c2 = std.mem.lastIndexOfScalar(u8, line[0..c1], ',').?;
        const c3 = std.mem.lastIndexOfScalar(u8, line[0..c2], ',').?;
        const next = try std.fmt.allocPrint(allocator, "{s},<T>{s},<T>", .{ line[0..c3], line[c2..c1] });
        allocator.free(line);
        line = next;
    } else if (std.mem.indexOf(u8, line, " Stored ") != null) {
        if (std.mem.lastIndexOf(u8, line, " in ")) |i| {
            const next = try std.fmt.allocPrint(allocator, "{s} in <T>", .{line[0..i]});
            allocator.free(line);
            line = next;
        }
    }
    return line;
}

fn lessThanStr(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Matches with equal scores are ordered by the core's qsort, which is not
/// stable and differs between libcs (macOS vs glibc on CI). Put tied rows in
/// a canonical order so the snapshot checks formatting and score order, not
/// the tie-break. CSV: consecutive rows with the same query, offset and
/// match_count. JSON: consecutive match objects with the same match_count.
fn canonicalizeTies(allocator: std.mem.Allocator, lines: [][]u8) !void {
    // CSV rows
    var i: usize = 0;
    while (i < lines.len) {
        const r = (try parseResultLine(allocator, lines[i])) orelse {
            i += 1;
            continue;
        };
        var j = i + 1;
        while (j < lines.len) : (j += 1) {
            const n = (try parseResultLine(allocator, lines[j])) orelse break;
            if (n.match_count != r.match_count or n.query_offset != r.query_offset or !std.mem.eql(u8, n.query, r.query)) break;
        }
        std.mem.sort([]u8, lines[i..j], {}, lessThanStr);
        i = j;
    }

    // JSON match objects: "    {", 7 field lines, "    }" or "    },"
    const block_len = 9;
    i = 0;
    while (i + block_len <= lines.len) {
        if (!std.mem.eql(u8, lines[i], "    {")) {
            i += 1;
            continue;
        }
        var j = i;
        while (j + block_len <= lines.len and std.mem.eql(u8, lines[j], "    {") and
            std.mem.eql(u8, lines[j + 1], lines[i + 1])) : (j += block_len)
        {}
        const count = (j - i) / block_len;
        if (count > 1) {
            const last_end = lines[j - 1];
            // Sort blocks by their joined field lines.
            const Block = struct { key: []u8, first: usize };
            const blocks = try allocator.alloc(Block, count);
            defer allocator.free(blocks);
            for (blocks, 0..) |*b, k| {
                const first = i + k * block_len;
                b.* = .{ .key = try std.mem.join(allocator, "\n", lines[first + 1 .. first + block_len - 1]), .first = first };
            }
            defer for (blocks) |b| allocator.free(b.key);
            std.mem.sort(Block, blocks, {}, struct {
                fn lt(_: void, a: Block, b: Block) bool {
                    return std.mem.lessThan(u8, a.key, b.key);
                }
            }.lt);
            const copy = try allocator.alloc([]u8, j - i);
            defer allocator.free(copy);
            for (blocks, 0..) |b, k| @memcpy(copy[k * block_len ..][0..block_len], lines[b.first..][0..block_len]);
            @memcpy(lines[i..j], copy);
            // Restore the separators: every block ends in "}," except that
            // the group's last block keeps the original last ending.
            for (0..count) |k| {
                const end_idx = i + k * block_len + block_len - 1;
                const want: []const u8 = if (k == count - 1) last_end else "    },";
                if (!std.mem.eql(u8, lines[end_idx], want)) {
                    // Swap in a line with the wanted ending from the group.
                    for (0..count) |m| {
                        const other = i + m * block_len + block_len - 1;
                        if (std.mem.eql(u8, lines[other], want)) {
                            std.mem.swap([]u8, &lines[end_idx], &lines[other]);
                            break;
                        }
                    }
                }
            }
        }
        i = if (j > i) j else i + 1;
    }
}

test "functional: output snapshot" {
    const allocator = testing.allocator;
    const io = testing.io;

    try dataset.ensureDataset(io, allocator, .ref_and_queries);

    var env = try Fixture.init(allocator, io, "snapshot");
    defer env.deinit();

    const repo = try Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
    defer allocator.free(repo);
    const ref_a = try std.fmt.allocPrint(allocator, "{s}/dataset/ref/11266.mp3", .{repo});
    defer allocator.free(ref_a);
    const ref_b = try std.fmt.allocPrint(allocator, "{s}/dataset/ref/173050.mp3", .{repo});
    defer allocator.free(ref_b);
    const q_a = try std.fmt.allocPrint(allocator, "{s}/dataset/queries/11266_69s-89s.mp3", .{repo});
    defer allocator.free(q_a);
    const q_b = try std.fmt.allocPrint(allocator, "{s}/dataset/queries/173050_86s-106s.mp3", .{repo});
    defer allocator.free(q_b);
    const comma = try std.fmt.allocPrint(allocator, "{s}/Crosby, Stills.mp3", .{env.home});
    defer allocator.free(comma);
    // Distinct audio (not a copy of ref-a/ref-b): identical references would
    // produce equal-score ties whose order depends on the libc qsort.
    try copyFileTo(io, allocator, "dataset/ref/1051039.mp3", comma);

    const Step = struct { title: []const u8, args: []const []const u8, stream: enum { stdout, stderr } };
    // Stable --with-ids identifiers keep internal ids independent of where
    // the repository is checked out.
    const steps = [_]Step{
        .{ .title = "store human", .args = &.{ "store", "--with-ids", ref_a, "ref-a", ref_b, "ref-b" }, .stream = .stderr },
        .{ .title = "store human (skip)", .args = &.{ "store", "--with-ids", ref_a, "ref-a" }, .stream = .stderr },
        .{ .title = "store csv (skip)", .args = &.{ "store", "--format", "csv", "--with-ids", ref_a, "ref-a" }, .stream = .stderr },
        .{ .title = "store csv (forced)", .args = &.{ "store", "-f", "--format", "csv", "--with-ids", ref_a, "ref-a", ref_b, "ref-b" }, .stream = .stderr },
        .{ .title = "store json (skip)", .args = &.{ "store", "--format", "json", "--with-ids", ref_b, "ref-b" }, .stream = .stderr },
        .{ .title = "store json (forced)", .args = &.{ "store", "-f", "--format", "json", "--with-ids", ref_b, "ref-b" }, .stream = .stderr },
        .{ .title = "store human (comma identifier)", .args = &.{ "store", "--with-ids", comma, "Crosby, Stills" }, .stream = .stderr },
        .{ .title = "query csv", .args = &.{ "query", q_a, q_b }, .stream = .stdout },
        .{ .title = "query json", .args = &.{ "query", "--format", "json", q_a, q_b }, .stream = .stdout },
        .{ .title = "query csv --fragmented", .args = &.{ "query", "--fragmented", ref_a }, .stream = .stdout },
        .{ .title = "query json --fragmented", .args = &.{ "query", "--fragmented", "--format", "json", ref_b }, .stream = .stdout },
        .{ .title = "query csv comma path", .args = &.{ "query", comma }, .stream = .stdout },
        .{ .title = "query csv --no-identity-match (--with-ids)", .args = &.{ "query", "--no-identity-match", "--with-ids", ref_b, "ref-b" }, .stream = .stdout },
        .{ .title = "stats", .args = &.{"stats"}, .stream = .stdout },
    };

    var transcript: std.Io.Writer.Allocating = .init(allocator);
    defer transcript.deinit();
    for (steps) |step| {
        const r = try env.run(step.args, 0);
        defer r.deinit();
        try transcript.writer.print("== {s}\n", .{step.title});
        const text = if (step.stream == .stdout) r.stdout else r.stderr;
        var masked_lines: std.ArrayList([]u8) = .empty;
        defer {
            for (masked_lines.items) |l| allocator.free(l);
            masked_lines.deinit(allocator);
        }
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            if (raw.len == 0) continue;
            try masked_lines.append(allocator, try maskVolatile(allocator, raw, repo, env.home));
        }
        try canonicalizeTies(allocator, masked_lines.items);
        for (masked_lines.items) |l| try transcript.writer.print("{s}\n", .{l});
    }
    const actual = transcript.written();

    const environment = try snapshotEnvironment(allocator, io);
    defer allocator.free(environment);

    if (getEnvVar("OLAF_UPDATE_GOLDEN") != null) {
        try Io.Dir.cwd().createDirPath(io, "tests/golden");
        const f = try Io.Dir.cwd().createFile(io, GOLDEN_SNAPSHOT, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, environment);
        try f.writeStreamingAll(io, "\n");
        try f.writeStreamingAll(io, actual);
        return;
    }

    const golden = Io.Dir.cwd().readFileAlloc(io, GOLDEN_SNAPSHOT, allocator, .limited(4 * 1024 * 1024)) catch |err| {
        std.debug.print("\nMissing {s} ({}); generate it with OLAF_UPDATE_GOLDEN=1 zig build test\n", .{ GOLDEN_SNAPSHOT, err });
        return err;
    };
    defer allocator.free(golden);
    const header_end = std.mem.indexOfScalar(u8, golden, '\n') orelse return error.MalformedGolden;
    if (!std.mem.eql(u8, golden[0..header_end], environment)) {
        std.debug.print("\nSkipping output snapshot: {s} was generated in '{s}', this is '{s}'. Regenerate it here with OLAF_UPDATE_GOLDEN=1 before refactoring.\n", .{ GOLDEN_SNAPSHOT, golden[0..header_end], environment });
        return error.SkipZigTest;
    }
    const expected = golden[header_end + 1 ..];
    testing.expectEqualStrings(expected, actual) catch |err| {
        std.debug.print("\nOutput differs from {s}. If the change is intended, regenerate with OLAF_UPDATE_GOLDEN=1 zig build test\n", .{GOLDEN_SNAPSHOT});
        return err;
    };
}

test "functional: delete before anything is stored" {
    const allocator = testing.allocator;
    const io = testing.io;
    try dataset.ensureDataset(io, allocator, .ref_only);

    var env = try Fixture.init(allocator, io, "delete_empty");
    defer env.deinit();

    // Used to exit(-42) inside the core with an LMDB error.
    const r = try env.run(&.{ "delete", env.ref }, 0);
    defer r.deinit();
    try testing.expect(std.mem.indexOf(u8, r.stderr, "no database yet") != null);
}

test "functional: config typos and wrong types are reported" {
    const allocator = testing.allocator;
    const io = testing.io;

    var env = try Fixture.init(allocator, io, "config_check");
    defer env.deinit();

    // A misspelled key used to be ignored without a word.
    try env.writeConfig(
        \\{"db_folder": "~/.olaf/db/", "cache_folder": "~/.olaf/cache/", "$schema": "x", "max_result": 7}
    );
    {
        const r = try env.run(&.{"config"}, 0);
        defer r.deinit();
        try testing.expect(std.mem.indexOf(u8, r.stderr, "unknown setting 'max_result'") != null);
        try testing.expect(std.mem.indexOf(u8, r.stderr, "$schema") == null);
    }

    // A wrongly typed value used to fall back to the default silently.
    try env.writeConfig(
        \\{"db_folder": "~/.olaf/db/", "cache_folder": "~/.olaf/cache/", "verbose": "yes"}
    );
    const r = try env.run(&.{"config"}, 1);
    defer r.deinit();
    try testing.expect(std.mem.indexOf(u8, r.stderr, "'verbose' must be a boolean") != null);
}

test "functional: cache + store_cached stores what store stores" {
    const allocator = testing.allocator;
    const io = testing.io;
    try dataset.ensureDataset(io, allocator, .ref_only);

    var direct = try Fixture.init(allocator, io, "store_direct");
    defer direct.deinit();
    try direct.ok(&.{ "store", direct.ref });

    var cached = try Fixture.init(allocator, io, "store_via_cache");
    defer cached.deinit();
    try cached.ok(&.{ "cache", cached.ref });
    try cached.ok(&.{"store_cached"});

    // Duration and fingerprint count used to differ: the core cache writer
    // approximated the duration and stored the .tdb header as a fingerprint.
    const stats_direct = try direct.run(&.{"stats"}, 0);
    defer stats_direct.deinit();
    const stats_cached = try cached.run(&.{"stats"}, 0);
    defer stats_cached.deinit();
    try testing.expectEqualStrings(stats_direct.stdout, stats_cached.stdout);

    const q_direct = try direct.run(&.{ "query", direct.ref }, 0);
    defer q_direct.deinit();
    const q_cached = try cached.run(&.{ "query", cached.ref }, 0);
    defer q_cached.deinit();
    const top_direct = (try firstResultLine(allocator, q_direct.stdout)) orelse return error.NoResultLine;
    const top_cached = (try firstResultLine(allocator, q_cached.stdout)) orelse return error.NoResultLine;
    try testing.expectEqual(top_direct.match_count, top_cached.match_count);
    try testing.expectEqualStrings(top_direct.ref_id, top_cached.ref_id);
}

test "functional: temp audio goes to TMPDIR" {
    const allocator = testing.allocator;
    const io = testing.io;
    try dataset.ensureDataset(io, allocator, .ref_only);

    var env = try Fixture.init(allocator, io, "tmpdir");
    defer env.deinit();
    const tmp = try std.fmt.allocPrint(allocator, "{s}/tmp", .{env.home});
    defer allocator.free(tmp);
    try Io.Dir.cwd().createDirPath(io, tmp);
    try env.env_map.put("TMPDIR", tmp);

    // Used to be /tmp unconditionally.
    try env.ok(&.{ "store", env.ref });
    try testing.expect(try fileExists(io, allocator, tmp, "olaf_raw_audio_cache"));
}

test "functional: --fragmented reports an unreadable duration clearly" {
    const allocator = testing.allocator;
    const io = testing.io;

    var env = try Fixture.init(allocator, io, "bad_duration");
    defer env.deinit();
    const bad = try writeBadAudioFile(&env);
    defer allocator.free(bad);

    // Used to fail with a bare InvalidCharacter parse error.
    const r = try env.run(&.{ "query", "--fragmented", bad }, 1);
    defer r.deinit();
    try testing.expect(std.mem.indexOf(u8, r.stderr, "could not read the duration of") != null);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "DurationUnavailable") != null);
}

test "functional: no home directory is an error, not a ./~ folder" {
    const allocator = testing.allocator;
    const io = testing.io;

    var env = try Fixture.init(allocator, io, "no_home");
    defer env.deinit();
    _ = env.env_map.swapRemove("HOME");
    _ = env.env_map.swapRemove("USERPROFILE");

    // Run from the fixture's home so a stray "~" folder would land there.
    const script = try std.fmt.allocPrint(allocator, "cd '{s}' && '{s}' stats", .{ env.home, env.bin });
    defer allocator.free(script);
    const r = try env.shell(script, 1);
    defer r.deinit();
    try testing.expect(std.mem.indexOf(u8, r.stderr, "neither HOME nor USERPROFILE is set") != null);
    try testing.expect(!try fileExists(io, allocator, env.home, "~"));
}

test "functional: delete skips files that are not indexed" {
    const allocator = testing.allocator;
    const io = testing.io;
    try dataset.ensureDataset(io, allocator, .ref_only);

    var env = try Fixture.init(allocator, io, "delete_unindexed");
    defer env.deinit();
    var other_buf: [std.fs.max_path_bytes]u8 = undefined;
    const other_n = try Io.Dir.cwd().realPathFile(io, "dataset/ref/173050.mp3", &other_buf);
    const other = other_buf[0..other_n];

    try env.ok(&.{ "store", env.ref });
    // The unindexed file comes first: it used to exit(-42) in the core, so
    // the indexed file after it was never deleted.
    const r = try env.run(&.{ "delete", other, env.ref }, 0);
    defer r.deinit();
    try testing.expect(std.mem.indexOf(u8, r.stderr, "not indexed") != null);
    try testing.expectEqual(@as(u32, 0), try env.songCount());
}

test "functional: an unwritable database is reported before any work starts" {
    const allocator = testing.allocator;
    const io = testing.io;
    try dataset.ensureDataset(io, allocator, .ref_only);

    var env = try Fixture.init(allocator, io, "db_readonly");
    defer env.deinit();
    try env.ok(&.{ "store", env.ref });

    // As root (e.g. in a container) chmod does not stop writes, and the
    // commands below simply succeed: skip then.
    const lock = try std.fmt.allocPrint(allocator, "chmod a-w '{s}/data.mdb' && [ ! -w '{s}/data.mdb' ]", .{ env.db_dir, env.db_dir });
    defer allocator.free(lock);
    const locked = env.shell(lock, 0) catch return error.SkipZigTest;
    locked.deinit();
    const unlock = try std.fmt.allocPrint(allocator, "chmod u+w '{s}/data.mdb'", .{env.db_dir});
    defer allocator.free(unlock);
    defer if (env.shell(unlock, 0)) |r| r.deinit() else |_| {};

    // Used to exit(214) from inside the core ("Database Error in
    // 'mdb_env_open': Permission denied"), for queries too.
    for ([_][]const []const u8{
        &.{ "query", env.ref },
        &.{ "store", "-f", "--threads", "2", env.ref },
    }) |args| {
        const r = try env.run(args, 1);
        defer r.deinit();
        try testing.expect(std.mem.indexOf(u8, r.stderr, "is not readable and writable") != null);
        try testing.expect(std.mem.indexOf(u8, r.stderr, "Database Error") == null);
    }
}

test "functional: cache recovers from an interrupted run, -f re-caches" {
    const allocator = testing.allocator;
    const io = testing.io;
    try dataset.ensureDataset(io, allocator, .ref_only);

    var env = try Fixture.init(allocator, io, "cache_resume");
    defer env.deinit();

    // What an interrupted run used to leave: a .tdb without its .meta. It
    // was then skipped as "already present" forever.
    try touchFile(io, allocator, env.cache_dir, "12345.tdb");
    {
        const r = try env.run(&.{ "cache", "--with-ids", env.ref, "12345" }, 0);
        defer r.deinit();
        try testing.expect(std.mem.indexOf(u8, r.stdout, "SKIPPED") == null);
    }
    try testing.expect(try fileExists(io, allocator, env.cache_dir, "12345.meta"));
    try testing.expectEqual(@as(usize, 0), try countFilesWithSuffix(io, env.cache_dir, ".part"));
    {
        const r = try env.run(&.{ "cache", "--with-ids", env.ref, "12345" }, 0);
        defer r.deinit();
        try testing.expect(std.mem.indexOf(u8, r.stdout, "SKIPPED") != null);
    }
    {
        const r = try env.run(&.{ "cache", "-f", "--with-ids", env.ref, "12345" }, 0);
        defer r.deinit();
        try testing.expect(std.mem.indexOf(u8, r.stdout, "SKIPPED") == null);
    }
}

test "functional: store_cached reports a malformed cache file and stores the rest" {
    const allocator = testing.allocator;
    const io = testing.io;
    try dataset.ensureDataset(io, allocator, .ref_only);

    var env = try Fixture.init(allocator, io, "store_cached_bad");
    defer env.deinit();
    try env.ok(&.{ "cache", env.ref });

    // A second, corrupt entry: valid .meta, garbage fingerprint lines.
    const tdb = try std.fmt.allocPrint(allocator, "{s}/1.tdb", .{env.cache_dir});
    defer allocator.free(tdb);
    const meta = try std.fmt.allocPrint(allocator, "{s}/1.meta", .{env.cache_dir});
    defer allocator.free(meta);
    for ([_][2][]const u8{ .{ tdb, "fp_hash, t1\nnot-a-number, x\n" }, .{ meta, "path=corrupt\nduration=1.0\nfingerprints=1\n" } }) |pair| {
        const f = try Io.Dir.cwd().createFile(io, pair[0], .{});
        defer f.close(io);
        try f.writeStreamingAll(io, pair[1]);
    }

    // Used to abort without any per-file line or summary.
    const r = try env.run(&.{"store_cached"}, 1);
    defer r.deinit();
    try testing.expect(std.mem.indexOf(u8, r.stdout, "corrupt, FAILED: MalformedCacheFile") != null);
    try testing.expect(std.mem.indexOf(u8, r.stdout, "stored from cache") != null);
    try testing.expect(std.mem.indexOf(u8, r.stdout, "Stored 1 cache file(s), skipped 0 already indexed, 1 failed") != null);
    try testing.expectEqual(@as(u32, 1), try env.songCount());
}

test "functional: the shipped example config is valid and uses the defaults" {
    const allocator = testing.allocator;
    const io = testing.io;

    var env = try Fixture.init(allocator, io, "example_config");
    defer env.deinit();
    const example = try Io.Dir.cwd().readFileAlloc(io, "cli/olaf_config.example.json", allocator, .limited(64 * 1024));
    defer allocator.free(example);
    try env.writeConfig(example);

    const r = try env.run(&.{"config"}, 0);
    defer r.deinit();
    try testing.expect(std.mem.indexOf(u8, r.stderr, "unknown setting") == null);
    // The release used to ship an example with a 2000 Hz sample rate as the
    // live config, making fingerprints incompatible with a 16 kHz index.
    try testing.expect(std.mem.indexOf(u8, r.stdout, "target_sample_rate: 16000") != null);
    try testing.expect(std.mem.indexOf(u8, r.stdout, ".flac") != null);
}

test "functional: an empty TMPDIR is ignored" {
    const allocator = testing.allocator;
    const io = testing.io;
    try dataset.ensureDataset(io, allocator, .ref_only);

    var env = try Fixture.init(allocator, io, "tmpdir_empty");
    defer env.deinit();
    try env.env_map.put("TMPDIR", "");

    // Used to write the temp audio under ./olaf_raw_audio_cache.
    const script = try std.fmt.allocPrint(allocator, "cd '{s}' && '{s}' store '{s}'", .{ env.home, env.bin, env.ref });
    defer allocator.free(script);
    (try env.shell(script, 0)).deinit();
    try testing.expect(!try fileExists(io, allocator, env.home, "olaf_raw_audio_cache"));
}

test "functional: live microphone results reach a redirected stdout" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = testing.io;
    try dataset.ensureDataset(io, allocator, .ref_only);

    var env = try Fixture.init(allocator, io, "live_flush");
    defer env.deinit();
    try env.ok(&.{ "store", env.ref });
    // An endless, real-time "microphone": ffmpeg's noise source.
    try env.writeConfig(
        \\{"db_folder": "~/.olaf/db/", "cache_folder": "~/.olaf/cache/",
        \\ "microphone_input_format": "lavfi", "microphone_device": "anoisesrc=d=600,arealtime"}
    );

    // Results print every 3 s of audio. They used to sit in libc's stdout
    // buffer and were lost when the process was terminated.
    const out = try std.fmt.allocPrint(allocator, "{s}/live.csv", .{env.home});
    defer allocator.free(out);
    const script = try std.fmt.allocPrint(allocator, "'{s}' microphone > '{s}' 2>/dev/null & p=$!; sleep 5; kill -TERM $p; wait $p; true", .{ env.bin, out });
    defer allocator.free(script);
    (try env.shell(script, 0)).deinit();

    const content = try Io.Dir.cwd().readFileAlloc(io, out, allocator, .limited(1 << 20));
    defer allocator.free(content);
    try testing.expect(std.mem.indexOf(u8, content, "1 ,1 ,microphone,") != null);
}

test "functional: a query whose only match is itself still reports a row" {
    const allocator = testing.allocator;
    const io = testing.io;
    try dataset.ensureDataset(io, allocator, .ref_only);

    var env = try Fixture.init(allocator, io, "self_only");
    defer env.deinit();
    try env.ok(&.{ "store", env.ref });

    // Used to print no row at all for this query (the self-match was
    // filtered and the core's "no results" row is only sent when there are
    // no matches at all).
    const r = try env.run(&.{ "query", "--no-identity-match", env.ref }, 0);
    defer r.deinit();
    const row = (try firstResultLine(allocator, r.stdout)) orelse return error.NoResultLine;
    try testing.expect(row.empty_match);
}

test "functional: long identifiers are stored and reported" {
    const allocator = testing.allocator;
    const io = testing.io;
    try dataset.ensureDataset(io, allocator, .ref_only);

    var env = try Fixture.init(allocator, io, "long_id");
    defer env.deinit();

    // A --with-ids identifier longer than the old 4 KiB record buffer: the
    // store succeeded but its summary failed, so the run reported a failure.
    const long_id = try allocator.alloc(u8, 5000);
    defer allocator.free(long_id);
    @memset(long_id, 'x');
    const r = try env.run(&.{ "store", "--format", "csv", "--with-ids", env.ref, long_id }, 0);
    defer r.deinit();
    try testing.expect(std.mem.indexOf(u8, r.stderr, long_id) != null);
}

test "functional: to_raw says when it reuses an existing output, -f re-converts" {
    const allocator = testing.allocator;
    const io = testing.io;
    try dataset.ensureDataset(io, allocator, .ref_only);

    var env = try Fixture.init(allocator, io, "to_raw_force");
    defer env.deinit();

    const run_in_home = struct {
        fn f(fx: *Fixture, force: bool) ![]u8 {
            const script = try std.fmt.allocPrint(fx.allocator, "cd '{s}' && '{s}' to_raw {s}'{s}'", .{ fx.home, fx.bin, if (force) "-f " else "", fx.ref });
            defer fx.allocator.free(script);
            const r = try fx.shell(script, 0);
            fx.allocator.free(r.stderr);
            return r.stdout;
        }
    }.f;

    const first = try run_in_home(&env, false);
    defer allocator.free(first);
    try testing.expect(std.mem.indexOf(u8, first, "SKIPPED") == null);
    // The existing output used to be reported as a fresh conversion.
    const again = try run_in_home(&env, false);
    defer allocator.free(again);
    try testing.expect(std.mem.indexOf(u8, again, "SKIPPED: output exists") != null);
    const forced = try run_in_home(&env, true);
    defer allocator.free(forced);
    try testing.expect(std.mem.indexOf(u8, forced, "SKIPPED") == null);
}

fn touchFile(io: Io, allocator: std.mem.Allocator, dir: []const u8, name: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ dir, name });
    defer allocator.free(path);
    if (std.fs.path.dirname(path)) |parent| try Io.Dir.cwd().createDirPath(io, parent);
    const f = try Io.Dir.cwd().createFile(io, path, .{});
    f.close(io);
}

fn fileExists(io: Io, allocator: std.mem.Allocator, dir: []const u8, name: []const u8) !bool {
    const path = try std.fs.path.join(allocator, &.{ dir, name });
    defer allocator.free(path);
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

test "functional: clear -f deletes only olaf files" {
    const allocator = testing.allocator;
    const io = testing.io;


    var env = try Fixture.init(allocator, io, "clear");
    defer env.deinit();

    for ([_][]const u8{ "data.mdb", "lock.mdb", "keep.txt", "sub/nested.mdb" }) |n| try touchFile(io, allocator, env.db_dir, n);
    for ([_][]const u8{ "1.tdb", "1.meta", "notes.txt" }) |n| try touchFile(io, allocator, env.cache_dir, n);

    try env.ok(&.{ "clear", "-f" });

    // Olaf-owned files are gone...
    try testing.expect(!try fileExists(io, allocator, env.db_dir, "data.mdb"));
    try testing.expect(!try fileExists(io, allocator, env.db_dir, "lock.mdb"));
    try testing.expect(!try fileExists(io, allocator, env.cache_dir, "1.tdb"));
    try testing.expect(!try fileExists(io, allocator, env.cache_dir, "1.meta"));
    // ...everything else, including nested files, survives.
    try testing.expect(try fileExists(io, allocator, env.db_dir, "keep.txt"));
    try testing.expect(try fileExists(io, allocator, env.db_dir, "sub/nested.mdb"));
    try testing.expect(try fileExists(io, allocator, env.cache_dir, "notes.txt"));
}

// ============================================================================
// Integration Tests - Testing End-to-End Workflows
// ============================================================================

test "integration: fingerprint extraction pipeline" {
    // This is a skeleton for testing the full pipeline:
    // Audio Input → Reader → Stream Processor → EP Extractor → FP Extractor

    std.debug.print("\nIntegration test skeleton - implement full pipeline test\n", .{});
}

// ============================================================================
// Benchmark Tests - Performance Testing
// ============================================================================

test "benchmark: fingerprint extraction speed" {
    // Skip benchmark in debug mode
    if (@import("builtin").mode == .Debug) {
        std.debug.print("\nSkipping benchmark in debug mode\n", .{});
        return error.SkipZigTest;
    }

    // This is a skeleton for benchmarking fingerprint extraction
    std.debug.print("\nBenchmark test skeleton - implement timing tests\n", .{});
}
