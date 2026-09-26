//! `olaf has` / `olaf rest has`: is this audio in the database? Each file is
//! queried in fragments (fragment_duration_in_seconds, like `query
//! --fragmented`); it is a match when the best match reaches the threshold.
//! For a match whose reference identifier is an existing absolute path, its
//! tags are read with the system ffprobe (no tags when ffprobe is missing).
//! The evaluation and the record are shared by the local and REST commands.
const std = @import("std");
const Io = std.Io;
const json = std.json;
const debug = std.log.scoped(.olaf_cli_has).debug;

const olaf_cli_config = @import("olaf_cli_config.zig");
const olaf_cli_output = @import("olaf_cli_output.zig");
const olaf_cli_session = @import("olaf_cli_session.zig");
const olaf_cli_threading = @import("olaf_cli_threading.zig");
const olaf_cli_util = @import("olaf_cli_util.zig");
const olaf_cli_util_audio = @import("olaf_cli_util_audio.zig");

const Config = olaf_cli_config.Config;
const Match = olaf_cli_output.Match;
const AudioFileWithId = olaf_cli_util.AudioFileWithId;

/// `json` (default) or `human` (`--format text`).
pub const Format = olaf_cli_output.Format;

/// The matches of one fragment, best first as the core reports them.
pub const FragmentResult = struct {
    offset: f32,
    matches: []const Match,
};

pub const Verdict = struct {
    match: bool,
    /// The highest scoring match over all fragments (null: no match at all).
    best: ?Match,
    /// Offset of the fragment the best match was found in.
    best_offset: f32,
    threshold: u32,
    /// Fragments whose own best match is the same reference and reaches the threshold.
    fragments_matched: usize,
    fragments_total: usize,

    pub fn matchCount(v: Verdict) i32 {
        return if (v.best) |b| b.match_count else 0;
    }
};

fn bestOf(matches: []const Match) ?Match {
    var best: ?Match = null;
    for (matches) |m| {
        if (best == null or m.match_count > best.?.match_count) best = m;
    }
    return best;
}

pub fn evaluate(fragments: []const FragmentResult, threshold: u32) Verdict {
    var best: ?Match = null;
    var best_offset: f32 = 0;
    for (fragments) |f| {
        if (bestOf(f.matches)) |m| if (best == null or m.match_count > best.?.match_count) {
            best = m;
            best_offset = f.offset;
        };
    }
    const is_match = if (best) |b| b.match_count >= 0 and @as(u32, @intCast(b.match_count)) >= threshold else false;
    var matched: usize = 0;
    if (is_match) for (fragments) |f| {
        const m = bestOf(f.matches) orelse continue;
        if (m.match_identifier == best.?.match_identifier and m.match_count >= 0 and @as(u32, @intCast(m.match_count)) >= threshold) matched += 1;
    };
    return .{
        .match = is_match,
        .best = best,
        .best_offset = best_offset,
        .threshold = threshold,
        .fragments_matched = matched,
        .fragments_total = fragments.len,
    };
}

/// The tags of the audio file at `path` via
/// `ffprobe -v quiet -show_entries format_tags -of json <path>`, or null when
/// `path` is not an existing absolute file, or ffprobe is missing or fails.
pub fn readTags(arena: std.mem.Allocator, io: Io, path: []const u8) ?json.Value {
    if (!std.fs.path.isAbsolute(path)) return null;
    Io.Dir.cwd().access(io, path, .{}) catch return null;
    const r = std.process.run(arena, io, .{
        .argv = &.{ "ffprobe", "-v", "quiet", "-show_entries", "format_tags", "-of", "json", path },
    }) catch |err| {
        debug("no tags for {s}: ffprobe could not run ({})", .{ path, err });
        return null;
    };
    if (r.term != .exited or r.term.exited != 0) {
        debug("no tags for {s}: ffprobe failed", .{path});
        return null;
    }
    return tagsFromProbe(arena, r.stdout);
}

/// `format.tags` of ffprobe's JSON output; an empty object when the file has
/// no tags, null when the output is not ffprobe JSON.
fn tagsFromProbe(arena: std.mem.Allocator, probe_json: []const u8) ?json.Value {
    const v = json.parseFromSliceLeaky(json.Value, arena, probe_json, .{}) catch return null;
    if (v != .object) return null;
    const format = v.object.get("format") orelse return .{ .object = .empty };
    if (format != .object) return null;
    const tags = format.object.get("tags") orelse return .{ .object = .empty };
    return if (tags == .object) tags else null;
}

/// One record per file on stdout: a JSON line (with `tags`), or a text line.
pub fn writeRecord(allocator: std.mem.Allocator, format: Format, query_path: []const u8, v: Verdict, tags: ?json.Value) !void {
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try formatRecord(&out.writer, format, query_path, v, tags);
    olaf_cli_output.emitStdout(out.written());
}

pub fn formatRecord(w: *Io.Writer, format: Format, query_path: []const u8, v: Verdict, tags: ?json.Value) !void {
    switch (format) {
        .human, .csv => {
            if (v.match) {
                try w.print("{s}: match {s} (match_count {d}, {d}/{d} fragments)\n", .{ query_path, v.best.?.path, v.matchCount(), v.fragments_matched, v.fragments_total });
            } else {
                try w.print("{s}: no match (best match_count {d} < {d})\n", .{ query_path, v.matchCount(), v.threshold });
            }
        },
        .json => {
            try w.writeAll("{\"query_path\":");
            try olaf_cli_output.jsonString(w, query_path);
            try w.print(",\"match\":{},\"match_count\":{d},\"threshold\":{d},\"fragments_matched\":{d},\"fragments_total\":{d},\"reference\":", .{
                v.match, v.matchCount(), v.threshold, v.fragments_matched, v.fragments_total,
            });
            if (v.match) {
                const b = v.best.?;
                try w.writeAll("{\"path\":");
                try olaf_cli_output.jsonString(w, b.path);
                try w.print(",\"match_identifier\":{d},\"query_offset\":", .{b.match_identifier});
                try olaf_cli_output.cFloat(w, "%.3f", v.best_offset);
                try w.writeAll(",\"reference_start\":");
                try olaf_cli_output.cFloat(w, "%.3f", b.reference_start);
                try w.writeAll(",\"reference_stop\":");
                try olaf_cli_output.cFloat(w, "%.3f", b.reference_stop);
                try w.writeAll(",\"tags\":");
                if (tags) |t| try json.Stringify.value(t, .{}, w) else try w.writeAll("null");
                try w.writeByte('}');
            } else {
                try w.writeAll("null");
            }
            try w.writeAll("}\n");
        },
    }
}

// ---------------------------------------------------------------------------
// Local: `olaf has`
// ---------------------------------------------------------------------------

pub const Job = struct {
    io: Io,
    config: *const Config,
    threshold: u32,
    format: Format,
};

pub fn runLocal(allocator: std.mem.Allocator, files: []const AudioFileWithId, threads: u32, job: Job) !void {
    // Validate the fragment length once, not per file.
    _ = try olaf_cli_threading.fragments(0, job.config.fragment_duration_in_seconds);
    try olaf_cli_session.prepareDb(allocator, job.config, true);
    const failures = try olaf_cli_threading.forEachParallel(AudioFileWithId, Job, job.io, allocator, files, threads, job, localWorker, olaf_cli_threading.audioFileLabel);
    if (failures > 0) return error.ProcessingFailed;
}

fn localWorker(job: Job, file: AudioFileWithId, index: usize, total: usize, allocator: std.mem.Allocator) !void {
    _ = index;
    _ = total;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var results: std.ArrayList(FragmentResult) = .empty;
    var it = try olaf_cli_threading.fragments(try olaf_cli_util_audio.getAudioDuration(arena, job.io, file.path), job.config.fragment_duration_in_seconds);
    while (it.next()) |fragment| {
        const raw = try olaf_cli_threading.TempRaw.create(job.io, arena, file.path, job.config, fragment);
        defer raw.deinit();
        const matches = try olaf_cli_session.queryCollect(arena, raw.path, file.identifier, job.config, 0);
        try results.append(arena, .{ .offset = fragment.start, .matches = matches });
    }
    try report(arena, job.io, job.format, file.path, results.items, job.threshold);
}

/// Evaluate, read the tags of a matched reference and print the record.
pub fn report(arena: std.mem.Allocator, io: Io, format: Format, query_path: []const u8, fragments: []const FragmentResult, threshold: u32) !void {
    const v = evaluate(fragments, threshold);
    const tags = if (v.match and format == .json) readTags(arena, io, v.best.?.path) else null;
    try writeRecord(arena, format, query_path, v, tags);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn testMatch(count: i32, id: u32) Match {
    return .{ .match_count = count, .query_start = 0, .query_stop = 1, .path = "/ref.mp3", .match_identifier = id, .reference_start = 2, .reference_stop = 3 };
}

test "evaluate: best over fragments, threshold and fragments matched" {
    const f = [_]FragmentResult{
        .{ .offset = 0, .matches = &.{ testMatch(40, 1), testMatch(8, 2) } },
        .{ .offset = 30, .matches = &.{testMatch(90, 1)} },
        .{ .offset = 60, .matches = &.{testMatch(25, 2)} },
        .{ .offset = 90, .matches = &.{} },
    };
    const v = evaluate(&f, 20);
    try std.testing.expect(v.match);
    try std.testing.expectEqual(@as(i32, 90), v.matchCount());
    try std.testing.expectEqual(@as(f32, 30), v.best_offset);
    // Fragments 0 and 30 (reference 1); 60's best is another reference.
    try std.testing.expectEqual(@as(usize, 2), v.fragments_matched);
    try std.testing.expectEqual(@as(usize, 4), v.fragments_total);

    try std.testing.expect(evaluate(&f, 90).match);
    try std.testing.expect(!evaluate(&f, 91).match);
    const none = evaluate(&.{}, 20);
    try std.testing.expect(!none.match and none.best == null and none.matchCount() == 0);
}

test "tags come from ffprobe's format.tags" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tags = tagsFromProbe(arena,
        \\{"format": {"tags": {"title": "Politik", "artist": "SAMi"}}}
    ).?;
    try std.testing.expectEqualStrings("SAMi", tags.object.get("artist").?.string);
    try std.testing.expectEqual(@as(usize, 0), tagsFromProbe(arena, "{\"format\": {}}").?.object.count());
    try std.testing.expectEqual(@as(?json.Value, null), tagsFromProbe(arena, "not json"));
    // Not an absolute, existing path: no ffprobe call at all.
    try std.testing.expectEqual(@as(?json.Value, null), readTags(arena, std.testing.io, "relative.mp3"));
}

test "records: JSON with and without a reference, and text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const hit = evaluate(&.{.{ .offset = 30, .matches = &.{testMatch(50, 7)} }}, 20);
    const miss = evaluate(&.{.{ .offset = 0, .matches = &.{testMatch(9, 7)} }}, 20);

    var out: Io.Writer.Allocating = .init(arena);
    try formatRecord(&out.writer, .json, "/q \"1\".mp3", hit, null);
    const parsed = try json.parseFromSliceLeaky(json.Value, arena, out.written(), .{});
    try std.testing.expectEqualStrings("/q \"1\".mp3", parsed.object.get("query_path").?.string);
    const ref = parsed.object.get("reference").?.object;
    try std.testing.expectEqualStrings("/ref.mp3", ref.get("path").?.string);
    try std.testing.expect(ref.get("tags").? == .null);

    out.clearRetainingCapacity();
    try formatRecord(&out.writer, .json, "/q.mp3", miss, null);
    const p2 = try json.parseFromSliceLeaky(json.Value, arena, out.written(), .{});
    try std.testing.expect(!p2.object.get("match").?.bool and p2.object.get("reference").? == .null);

    out.clearRetainingCapacity();
    try formatRecord(&out.writer, .human, "/q.mp3", hit, null);
    try std.testing.expectEqualStrings("/q.mp3: match /ref.mp3 (match_count 50, 1/1 fragments)\n", out.written());
    out.clearRetainingCapacity();
    try formatRecord(&out.writer, .human, "/q.mp3", miss, null);
    try std.testing.expectEqualStrings("/q.mp3: no match (best match_count 9 < 20)\n", out.written());
}
