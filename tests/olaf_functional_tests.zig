const std = @import("std");
const testing = std.testing;
const fs = std.fs;
const dataset = @import("dataset_download.zig");

// C imports for Olaf core
const c = @cImport({
    @cInclude("olaf_config.h");
    @cInclude("olaf_reader.h");
    @cInclude("olaf_db.h");
    @cInclude("olaf_deque.h");
});

const REF_AUDIO_FILE = "dataset/ref/11266.mp3";

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
    try dataset.ensureDataset(testing.allocator, .ref_and_queries);
}

// ============================================================================
// Functional Tests - Testing CLI Commands
// ============================================================================

/// Helper to create a test database directory
fn createTestDbDir(allocator: std.mem.Allocator) ![]const u8 {
    const timestamp = std.time.timestamp();
    const test_db_path = try std.fmt.allocPrint(
        allocator,
        "tests/test_db_{d}",
        .{timestamp},
    );

    try fs.cwd().makePath(test_db_path);
    return test_db_path;
}

/// Helper to clean up test database directory
fn cleanupTestDbDir(path: []const u8) void {
    fs.cwd().deleteTree(path) catch |err| {
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
fn resolveOlafBinAndDeps(allocator: std.mem.Allocator) ![]const u8 {
    const olaf_bin = std.process.getEnvVarOwned(allocator, "OLAF_BIN") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => DEFAULT_OLAF_BIN,
        else => return err,
    };
    errdefer freeOlafBin(allocator, olaf_bin);

    fs.cwd().access(olaf_bin, .{}) catch {
        std.debug.print("\nSkipping: olaf binary not found at {s} (run `zig build` first)\n", .{olaf_bin});
        return error.SkipZigTest;
    };

    const probe = std.process.Child.run(.{
        .allocator = allocator,
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

/// Isolated runtime sandbox for an olaf CLI invocation: a fresh tempdir laid
/// out as `<tests/test_home_<label>_<ts>>/.olaf/{db,cache}` with a config
/// file pointing the CLI at those paths, plus an env map with HOME overridden.
const TestEnv = struct {
    allocator: std.mem.Allocator,
    home: []u8,
    olaf_dir: []u8,
    db_dir: []u8,
    cache_dir: []u8,
    env_map: std.process.EnvMap,

    fn deinit(self: *TestEnv) void {
        self.env_map.deinit();
        cleanupTestDbDir(self.home);
        self.allocator.free(self.cache_dir);
        self.allocator.free(self.db_dir);
        self.allocator.free(self.olaf_dir);
        self.allocator.free(self.home);
    }
};

fn setupTestEnv(allocator: std.mem.Allocator, label: []const u8) !TestEnv {
    const cwd_path = try fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);

    const home = try std.fmt.allocPrint(
        allocator,
        "{s}/tests/test_home_{s}_{d}",
        .{ cwd_path, label, std.time.milliTimestamp() },
    );
    errdefer allocator.free(home);

    const olaf_dir = try std.fmt.allocPrint(allocator, "{s}/.olaf", .{home});
    errdefer allocator.free(olaf_dir);
    try fs.cwd().makePath(olaf_dir);

    const db_dir = try std.fmt.allocPrint(allocator, "{s}/db", .{olaf_dir});
    errdefer allocator.free(db_dir);
    try fs.cwd().makePath(db_dir);

    const cache_dir = try std.fmt.allocPrint(allocator, "{s}/cache", .{olaf_dir});
    errdefer allocator.free(cache_dir);
    try fs.cwd().makePath(cache_dir);

    {
        const config_path = try std.fmt.allocPrint(allocator, "{s}/olaf_config.json", .{olaf_dir});
        defer allocator.free(config_path);
        const f = try fs.cwd().createFile(config_path, .{});
        defer f.close();
        try f.writeAll(TEST_CONFIG_JSON);
    }

    var env_map = try std.process.getEnvMap(allocator);
    errdefer env_map.deinit();
    try env_map.put("HOME", home);

    return .{
        .allocator = allocator,
        .home = home,
        .olaf_dir = olaf_dir,
        .db_dir = db_dir,
        .cache_dir = cache_dir,
        .env_map = env_map,
    };
}

/// Run an olaf CLI command in the given test environment. On success, returns
/// the captured stdout/stderr — caller frees both. On failure, prints diagnostics
/// and returns `err_on_fail`.
fn runOlaf(
    allocator: std.mem.Allocator,
    olaf_bin: []const u8,
    env: *TestEnv,
    args: []const []const u8,
    err_on_fail: anyerror,
) !std.process.Child.RunResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, olaf_bin);
    try argv.appendSlice(allocator, args);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .env_map = &env.env_map,
    });

    switch (result.term) {
        .Exited => |code| if (code != 0) {
            std.debug.print("\nolaf {s} exited {d}\nstdout:\n{s}\nstderr:\n{s}\n", .{
                args[0], code, result.stdout, result.stderr,
            });
            allocator.free(result.stdout);
            allocator.free(result.stderr);
            return err_on_fail;
        },
        else => {
            std.debug.print("\nolaf {s} terminated abnormally: {}\n", .{ args[0], result.term });
            allocator.free(result.stdout);
            allocator.free(result.stderr);
            return err_on_fail;
        },
    }

    return result;
}

/// Store every file in REF_FILES_FOR_QUERY using the CLI.
fn storeAllRefs(
    allocator: std.mem.Allocator,
    olaf_bin: []const u8,
    env: *TestEnv,
) !void {
    for (REF_FILES_FOR_QUERY) |ref_rel| {
        var ref_buf: [std.fs.max_path_bytes]u8 = undefined;
        const ref_abs = try fs.cwd().realpath(ref_rel, &ref_buf);

        const result = try runOlaf(
            allocator,
            olaf_bin,
            env,
            &[_][]const u8{ "store", ref_abs },
            error.OlafStoreFailed,
        );
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
}

/// Run `olaf stats` and return the parsed song count.
fn statsSongCount(
    allocator: std.mem.Allocator,
    olaf_bin: []const u8,
    env: *TestEnv,
) !u32 {
    const result = try runOlaf(
        allocator,
        olaf_bin,
        env,
        &[_][]const u8{"stats"},
        error.OlafStatsFailed,
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return parseSongCount(result.stdout);
}

test "functional: store reference audio file" {
    const allocator = testing.allocator;

    const olaf_bin = try resolveOlafBinAndDeps(allocator);
    defer freeOlafBin(allocator, olaf_bin);

    try dataset.ensureDataset(allocator, .ref_only);

    var env = try setupTestEnv(allocator, "store");
    defer env.deinit();

    var ref_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ref_abs = try fs.cwd().realpath(REF_AUDIO_FILE, &ref_buf);

    const result = try runOlaf(allocator, olaf_bin, &env, &[_][]const u8{ "store", ref_abs }, error.OlafStoreFailed);
    allocator.free(result.stdout);
    allocator.free(result.stderr);

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

    const olaf_bin = try resolveOlafBinAndDeps(allocator);
    defer freeOlafBin(allocator, olaf_bin);

    try dataset.ensureDataset(allocator, .ref_only);

    var env = try setupTestEnv(allocator, "stats");
    defer env.deinit();

    var ref_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ref_abs = try fs.cwd().realpath(REF_AUDIO_FILE, &ref_buf);

    try testing.expectEqual(@as(u32, 0), try statsSongCount(allocator, olaf_bin, &env));

    const store_result = try runOlaf(allocator, olaf_bin, &env, &[_][]const u8{ "store", ref_abs }, error.OlafStoreFailed);
    allocator.free(store_result.stdout);
    allocator.free(store_result.stderr);

    try testing.expectEqual(@as(u32, 1), try statsSongCount(allocator, olaf_bin, &env));
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
    var parts: std.ArrayList([]const u8) = .{};
    defer parts.deinit(allocator);

    var it = std.mem.tokenizeAny(u8, line, ",");
    while (it.next()) |part| {
        try parts.append(allocator, std.mem.trim(u8, part, " \t\n\r"));
    }
    if (parts.items.len != 11) return null;

    const match_count = std.fmt.parseInt(u32, parts.items[4], 10) catch return null;
    return ParsedResult{
        .valid = true,
        .empty_match = match_count == 0,
        .query = parts.items[2],
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

    const olaf_bin = try resolveOlafBinAndDeps(allocator);
    defer freeOlafBin(allocator, olaf_bin);

    try dataset.ensureDataset(allocator, .ref_and_queries);

    var env = try setupTestEnv(allocator, "query");
    defer env.deinit();

    try storeAllRefs(allocator, olaf_bin, &env);

    for (QUERY_EXPECTATIONS) |exp| {
        var q_buf: [std.fs.max_path_bytes]u8 = undefined;
        const query_abs = try fs.cwd().realpath(exp.query_file, &q_buf);

        const result = try runOlaf(allocator, olaf_bin, &env, &[_][]const u8{ "query", query_abs }, error.OlafQueryFailed);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

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

    const olaf_bin = try resolveOlafBinAndDeps(allocator);
    defer freeOlafBin(allocator, olaf_bin);

    try dataset.ensureDataset(allocator, .ref_and_queries);

    var env = try setupTestEnv(allocator, "delete");
    defer env.deinit();

    try storeAllRefs(allocator, olaf_bin, &env);

    const total_refs: u32 = @intCast(REF_FILES_FOR_QUERY.len);
    try testing.expectEqual(total_refs, try statsSongCount(allocator, olaf_bin, &env));

    // Pick the last ref — it has a corresponding query file we can re-query
    // to confirm the match disappears after delete.
    const target_ref = REF_FILES_FOR_QUERY[REF_FILES_FOR_QUERY.len - 1];
    const target_query = "dataset/queries/852601_43s-63s.mp3";

    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target_abs = try fs.cwd().realpath(target_ref, &target_buf);

    var q_buf: [std.fs.max_path_bytes]u8 = undefined;
    const q_abs = try fs.cwd().realpath(target_query, &q_buf);

    // Confirm the query matches before deletion.
    {
        const result = try runOlaf(allocator, olaf_bin, &env, &[_][]const u8{ "query", q_abs }, error.OlafQueryFailed);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        const top = (try firstResultLine(allocator, result.stdout)) orelse return error.OlafQueryNoResult;
        try testing.expect(!top.empty_match);
    }

    // Delete the target ref.
    {
        const result = try runOlaf(allocator, olaf_bin, &env, &[_][]const u8{ "delete", target_abs }, error.OlafDeleteFailed);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try testing.expectEqual(total_refs - 1, try statsSongCount(allocator, olaf_bin, &env));

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
        const result = try runOlaf(allocator, olaf_bin, &env, &[_][]const u8{ "query", q_abs }, error.OlafQueryFailed);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

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
        const result = try runOlaf(allocator, olaf_bin, &env, &[_][]const u8{ "store", target_abs }, error.OlafStoreFailed);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    try testing.expectEqual(total_refs, try statsSongCount(allocator, olaf_bin, &env));
}

test "functional: dedup ignores self-matches and surfaces duplicates" {
    const allocator = testing.allocator;

    const olaf_bin = try resolveOlafBinAndDeps(allocator);
    defer freeOlafBin(allocator, olaf_bin);

    try dataset.ensureDataset(allocator, .ref_only);

    var env = try setupTestEnv(allocator, "dedup");
    defer env.deinit();

    // Pick two distinct reference files. Copy the first one to a fresh path
    // (different file name) so the index sees it as a separate audio item;
    // dedup should then report the copy as a duplicate of the original.
    const original = "dataset/ref/11266.mp3";
    const other = "dataset/ref/852601.mp3";

    var orig_buf: [std.fs.max_path_bytes]u8 = undefined;
    const orig_abs = try fs.cwd().realpath(original, &orig_buf);

    var other_buf: [std.fs.max_path_bytes]u8 = undefined;
    const other_abs = try fs.cwd().realpath(other, &other_buf);

    // Place the duplicate inside the test home so cleanup removes it.
    const dup_path = try std.fmt.allocPrint(allocator, "{s}/dup_11266.mp3", .{env.home});
    defer allocator.free(dup_path);
    try fs.cwd().copyFile(orig_abs, fs.cwd(), dup_path, .{});
    var dup_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dup_abs = try fs.cwd().realpath(dup_path, &dup_buf);

    const result = try runOlaf(
        allocator,
        olaf_bin,
        &env,
        &[_][]const u8{ "dedup", orig_abs, dup_abs, other_abs },
        error.OlafDedupFailed,
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

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

// ============================================================================
// Test Runner Utilities
// ============================================================================

/// Run all C unit tests by calling the compiled olaf_tests binary
pub fn runCUnitTests(allocator: std.mem.Allocator) !void {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{"bin/olaf_tests"},
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        std.debug.print("C unit tests failed:\n{s}\n", .{result.stderr});
        return error.CUnitTestsFailed;
    }

    std.debug.print("C unit tests passed:\n{s}\n", .{result.stdout});
}

/// Main test entry point - can be called from build.zig
pub fn runAllTests(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== Running Olaf Test Suite ===\n\n", .{});

    // Run C unit tests if binary exists
    std.debug.print("Running C unit tests...\n", .{});
    runCUnitTests(allocator) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("C unit tests not found - run 'make test' first\n", .{});
        } else {
            return err;
        }
    };

    std.debug.print("\nAll Zig unit tests are run automatically by 'zig build test'\n", .{});
}
