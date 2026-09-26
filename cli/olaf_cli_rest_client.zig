//! `olaf rest store` / `olaf rest query`: store and query through one REST
//! endpoint (an `olaf rest serve`, or an `olaf rest serve-lb` combining several) instead
//! of the local database, printing exactly the records `olaf store` and
//! `olaf query` print. Combining databases is the endpoint's job: this only
//! turns its response envelope back into the local output.
const std = @import("std");
const Io = std.Io;
const json = std.json;
const rest = @import("olaf_rest");
const log = std.log.scoped(.olaf_rest_client);

const olaf_cli_config = @import("olaf_cli_config.zig");
const olaf_cli_has = @import("olaf_cli_has.zig");
const olaf_cli_output = @import("olaf_cli_output.zig");
const olaf_cli_threading = @import("olaf_cli_threading.zig");
const olaf_cli_util = @import("olaf_cli_util.zig");
const types = @import("olaf_cli_types.zig");

const Config = olaf_cli_config.Config;
const AudioFileWithId = olaf_cli_util.AudioFileWithId;

pub const Action = enum { store, query, has };

pub const Job = struct {
    io: Io,
    config: *const Config,
    /// Base URL of the endpoint, normalized.
    url: []const u8,
    action: Action,
    store_format: olaf_cli_output.StoreFormat,
    query_format: olaf_cli_output.OutputFormat,
    force: bool,
    allow_identity_match: bool,
    fragmented: bool,
    /// has: the match threshold and the record format (json / human).
    threshold: u32 = 0,
    has_format: olaf_cli_has.Format = .json,
};

/// The endpoint URL: the command's URL argument, else rest_endpoint.
pub fn endpointUrl(args: *const types.Args, config: *const Config) ![]const u8 {
    const url = args.endpoint orelse config.rest_endpoint;
    return rest.lb.normalizeUrl(url) orelse {
        std.log.err("'{s}' is not an http:// or https:// URL{s}", .{ url, if (args.endpoint == null) " (config 'rest_endpoint')" else "" });
        return error.InvalidConfigValue;
    };
}

/// Store or query every file through the endpoint, like `olaf store` /
/// `olaf query` do locally (same executor, --threads and failure handling).
pub fn run(allocator: std.mem.Allocator, files: []const AudioFileWithId, threads: u32, job: Job) !void {
    const failures = try olaf_cli_threading.forEachParallel(AudioFileWithId, Job, job.io, allocator, files, threads, job, worker, olaf_cli_threading.audioFileLabel);
    if (failures > 0) return error.ProcessingFailed;
}

fn worker(job: Job, file: AudioFileWithId, index: usize, total: usize, allocator: std.mem.Allocator) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const endpoint: rest.Endpoint = switch (job.action) {
        .store => .store,
        .query, .has => .query,
    };
    const params = rest.Params{
        .identifier = file.identifier,
        .force = job.force,
        .no_identity_match = !job.allow_identity_match,
        .fragmented = job.fragmented or job.action == .has,
    };
    var query_string: Io.Writer.Allocating = .init(arena);
    try rest.params.encodeQuery(&query_string.writer, endpoint, params);

    const max_body = @as(usize, job.config.rest_max_body_mb) * 1024 * 1024;
    const body = Io.Dir.cwd().readFileAlloc(job.io, file.path, arena, .limited(max_body)) catch |err| switch (err) {
        error.StreamTooLong => {
            std.log.err("{s} is larger than rest_max_body_mb ({d} MB)", .{ file.path, job.config.rest_max_body_mb });
            return error.FileTooBig;
        },
        else => |e| return e,
    };

    const sent = try rest.lb.send(arena, job.io, job.url, .{ .endpoint = endpoint, .params = params, .raw_query = query_string.written(), .body = body });
    const ok = try firstOk(sent.results);
    switch (job.action) {
        .store => try printStore(job, file, index, total, ok),
        .query => try printQuery(arena, job, file, index, total, ok, sent.summary),
        .has => try printHas(arena, job, file, ok, sent.summary),
    }
}

/// The first successful result; when there is none, every failure is logged
/// and the file fails with an error like the local one would.
fn firstOk(results: []const rest.Result) !rest.Result {
    for (results) |r| if (r.ok()) return r;
    var err: anyerror = error.RemoteRequestFailed;
    for (results) |r| {
        log.err("{s}: {s}", .{ r.endpoint, r.err orelse "failed" });
        if (r.status == 422) err = error.FFmpegFailed;
        if (r.status == 502) err = error.EndpointUnreachable;
    }
    return err;
}

fn printStore(job: Job, file: AudioFileWithId, index: usize, total: usize, r: rest.Result) !void {
    const data = r.data orelse return error.InvalidResponse;
    const internal_id: u32 = @intFromFloat(num(data, "internal_id") orelse return error.InvalidResponse);
    const action = if (data.object.get("action")) |a| (if (a == .string) a.string else "") else "";
    if (std.mem.eql(u8, action, "skip")) {
        return olaf_cli_output.writeStoreSkip(job.store_format, index, total, file.identifier, internal_id);
    }
    try olaf_cli_output.writeStoreSummary(job.store_format, .{
        .index = index,
        .total = total,
        .audio_identifier = file.identifier,
        .internal_id = internal_id,
        .fingerprints = @intFromFloat(num(data, "fingerprints") orelse 0),
        .audio_seconds = num(data, "audio_seconds_exact") orelse num(data, "audio_seconds") orelse 0,
        .cpu_seconds = num(data, "cpu_seconds") orelse 0,
    });
}

/// One CSV block or JSON object per query (per fragment when fragmented),
/// with the matches of the endpoint's summary for that query: already
/// combined over all databases behind the endpoint, best first.
fn printQuery(arena: std.mem.Allocator, job: Job, file: AudioFileWithId, index: usize, total: usize, r: rest.Result, summary: ?json.Value) !void {
    const data = r.data orelse return error.InvalidResponse;
    const queries = data.object.get("queries") orelse return error.InvalidResponse;
    if (queries != .array) return error.InvalidResponse;
    const all_matches = summaryMatches(summary);

    for (queries.array.items) |q| {
        const offset_text = numberText(q, "query_offset") orelse "0";
        const matches = try matchesAt(arena, all_matches, offset_text);
        const info = olaf_cli_output.QueryInfo{
            .index = index,
            .total = total,
            .path = file.path,
            .offset = std.fmt.parseFloat(f32, offset_text) catch 0,
        };
        switch (job.query_format) {
            .csv => try olaf_cli_output.writeQueryCsv(info, matches),
            .json => try olaf_cli_output.writeQueryJson(arena, info, .{
                .fingerprints = @intFromFloat(num(q, "query_fingerprints") orelse 0),
                .audio_seconds = num(q, "query_duration_seconds_exact") orelse num(q, "query_duration_seconds") orelse 0,
                .cpu_seconds = num(q, "search_time_seconds") orelse 0,
            }, matches),
        }
    }
}

/// `olaf has`'s record, from the fragments of the endpoint's answer and the
/// summary's matches per fragment (tags are read on this machine).
fn printHas(arena: std.mem.Allocator, job: Job, file: AudioFileWithId, r: rest.Result, summary: ?json.Value) !void {
    const data = r.data orelse return error.InvalidResponse;
    const queries = data.object.get("queries") orelse return error.InvalidResponse;
    if (queries != .array) return error.InvalidResponse;
    const all_matches = summaryMatches(summary);
    const fragments = try arena.alloc(olaf_cli_has.FragmentResult, queries.array.items.len);
    for (queries.array.items, fragments) |q, *f| {
        const offset_text = numberText(q, "query_offset") orelse "0";
        f.* = .{ .offset = std.fmt.parseFloat(f32, offset_text) catch 0, .matches = try matchesAt(arena, all_matches, offset_text) };
    }
    try olaf_cli_has.report(arena, job.io, job.has_format, file.path, fragments, job.threshold);
}

fn summaryMatches(summary: ?json.Value) []const json.Value {
    const s = summary orelse return &.{};
    if (s != .object) return &.{};
    const m = s.object.get("matches") orelse return &.{};
    return if (m == .array) m.array.items else &.{};
}

/// The summary matches of the query at `offset_text`, in summary order.
fn matchesAt(arena: std.mem.Allocator, all: []const json.Value, offset_text: []const u8) ![]olaf_cli_output.Match {
    var list: std.ArrayList(olaf_cli_output.Match) = .empty;
    for (all) |m| {
        if (m != .object) continue;
        const at = numberText(m, "query_offset") orelse "0";
        if (!std.mem.eql(u8, at, offset_text)) continue;
        try list.append(arena, .{
            .match_count = @intFromFloat(num(m, "match_count") orelse 0),
            .query_start = @floatCast(num(m, "query_start") orelse 0),
            .query_stop = @floatCast(num(m, "query_stop") orelse 0),
            .path = if (m.object.get("path")) |p| (if (p == .string) p.string else "") else "",
            .match_identifier = @intFromFloat(num(m, "match_identifier") orelse 0),
            .reference_start = @floatCast(num(m, "reference_start") orelse 0),
            .reference_stop = @floatCast(num(m, "reference_stop") orelse 0),
        });
    }
    return list.items;
}

fn num(v: json.Value, key: []const u8) ?f64 {
    if (v != .object) return null;
    return rest.envelope.number(v.object.get(key));
}

/// A number as the endpoint wrote it ("30.000"), to compare offsets exactly.
fn numberText(v: json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const n = v.object.get(key) orelse return null;
    return if (n == .number_string) n.number_string else null;
}

test "matchesAt keeps the matches of one query in summary order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const summary = try json.parseFromSliceLeaky(json.Value, arena,
        \\[{"query_offset":0.000,"match_count":9,"path":"a","match_identifier":1,"query_start":1.500,"query_stop":2.000,"reference_start":3.000,"reference_stop":4.000},
        \\ {"query_offset":30.000,"match_count":8,"path":"b","match_identifier":2},
        \\ {"query_offset":0.000,"match_count":7,"path":"c","match_identifier":3}]
    , rest.envelope.parse_options);
    const at0 = try matchesAt(arena, summary.array.items, "0.000");
    try std.testing.expectEqual(@as(usize, 2), at0.len);
    try std.testing.expectEqualStrings("a", at0[0].path);
    try std.testing.expectEqual(@as(f32, 1.5), at0[0].query_start);
    try std.testing.expectEqualStrings("c", at0[1].path);
    const at30 = try matchesAt(arena, summary.array.items, "30.000");
    try std.testing.expectEqual(@as(u32, 2), at30[0].match_identifier);
    try std.testing.expectEqual(@as(usize, 0), (try matchesAt(arena, summary.array.items, "60.000")).len);
}
