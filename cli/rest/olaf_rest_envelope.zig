//! The response envelope. Every endpoint, on `olaf rest serve` and on
//! `olaf rest serve-lb`, answers with the same shape: one entry in `results` per
//! database that served the request, plus a `summary` over all of them.
//!
//!   { "ok": true, "endpoint_count": 1, "endpoints_ok": 1,
//!     "results": [ { "endpoint": "local", "ok": true, "status": 200, "data": {...} } ],
//!     "summary": {...} }
//!
//! A failed endpoint has "error" instead of "data". A request that is
//! rejected before any database is asked (bad parameters, no body) has no
//! results and a top-level "error".
//!
//! Numbers are passed through as written (parsed with parse_numbers =
//! false), so a load balancer repeats a node's "1.936" byte for byte.
const std = @import("std");
const Io = std.Io;
const json = std.json;
const Value = json.Value;

const api = @import("olaf_rest_api.zig");
const Endpoint = api.Endpoint;
const Result = api.Result;

pub const parse_options: json.ParseOptions = .{ .parse_numbers = false };

/// HTTP status of a whole response: 200 when any endpoint succeeded, else the
/// status of the first failure.
pub fn status(results: []const Result) u16 {
    for (results) |r| if (r.ok()) return 200;
    return if (results.len > 0) results[0].status else 500;
}

pub const SummaryOptions = struct {
    /// query: keep at most this many matches per query (per query_offset),
    /// like one database returns at most max_results; null = all.
    max_matches: ?usize = null,
};

pub fn write(w: *Io.Writer, arena: std.mem.Allocator, endpoint: Endpoint, results: []const Result, opts: SummaryOptions) !void {
    var s: json.Stringify = .{ .writer = w, .options = .{ .whitespace = .indent_2 } };
    var n_ok: usize = 0;
    for (results) |r| n_ok += @intFromBool(r.ok());

    try s.beginObject();
    try s.objectField("ok");
    try s.write(n_ok > 0);
    try s.objectField("endpoint_count");
    try s.write(results.len);
    try s.objectField("endpoints_ok");
    try s.write(n_ok);
    try s.objectField("results");
    try s.beginArray();
    for (results) |r| {
        try s.beginObject();
        try s.objectField("endpoint");
        try s.write(r.endpoint);
        try s.objectField("ok");
        try s.write(r.ok());
        try s.objectField("status");
        try s.write(r.status);
        if (r.err) |e| {
            try s.objectField("error");
            try s.write(e);
        } else {
            try s.objectField("data");
            try s.write(r.data orelse Value.null);
        }
        try s.endObject();
    }
    try s.endArray();
    try s.objectField("summary");
    try s.write(try summary(arena, endpoint, results, opts));
    try s.endObject();
    try w.writeByte('\n');
}

/// A request rejected before any endpoint was asked.
pub fn writeError(w: *Io.Writer, message: []const u8) !void {
    var s: json.Stringify = .{ .writer = w, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(false);
    try s.objectField("endpoint_count");
    try s.write(0);
    try s.objectField("endpoints_ok");
    try s.write(0);
    try s.objectField("error");
    try s.write(message);
    try s.objectField("results");
    try s.beginArray();
    try s.endArray();
    try s.objectField("summary");
    try s.beginObject();
    try s.endObject();
    try s.endObject();
    try w.writeByte('\n');
}

/// The results of another instance's envelope (load balancer, CLI client).
/// A missing or malformed envelope is error.InvalidEnvelope; its top-level
/// "error" (a rejected request) is returned in `message`, its summary in
/// `summary_out` when given.
pub fn parse(arena: std.mem.Allocator, body: []const u8, message: *?[]const u8, summary_out: ?*?Value) ![]Result {
    const root = json.parseFromSliceLeaky(Value, arena, body, parse_options) catch return error.InvalidEnvelope;
    if (root != .object) return error.InvalidEnvelope;
    if (root.object.get("error")) |e| if (e == .string) {
        message.* = e.string;
    };
    if (summary_out) |out| out.* = root.object.get("summary");
    const list = root.object.get("results") orelse return error.InvalidEnvelope;
    if (list != .array) return error.InvalidEnvelope;
    const results = try arena.alloc(Result, list.array.items.len);
    for (list.array.items, results) |item, *r| {
        if (item != .object) return error.InvalidEnvelope;
        const o = item.object;
        const endpoint = o.get("endpoint") orelse return error.InvalidEnvelope;
        if (endpoint != .string) return error.InvalidEnvelope;
        r.* = .{
            .endpoint = endpoint.string,
            .status = if (number(o.get("status"))) |n| @intFromFloat(std.math.clamp(n, 0, 999)) else 200,
            .data = o.get("data"),
        };
        if (o.get("error")) |e| r.err = if (e == .string) e.string else "failed";
    }
    return results;
}

// ---------------------------------------------------------------------------
// Summaries
// ---------------------------------------------------------------------------

pub fn summary(arena: std.mem.Allocator, endpoint: Endpoint, results: []const Result, opts: SummaryOptions) !Value {
    return switch (endpoint) {
        .store => storeSummary(arena, results),
        .query => querySummary(arena, results, opts.max_matches),
        .stats => statsSummary(arena, results),
        .health => healthSummary(arena, results),
    };
}

/// Where the audio went: the first endpoint that stored (or skipped) it.
fn storeSummary(arena: std.mem.Allocator, results: []const Result) !Value {
    var o: json.ObjectMap = .empty;
    for (results) |r| {
        if (!r.ok()) continue;
        try o.put(arena, "endpoint", .{ .string = r.endpoint });
        if (r.data) |d| if (d == .object) {
            inline for (.{ "action", "audio_identifier", "internal_id" }) |k| {
                if (d.object.get(k)) |v| try o.put(arena, k, v);
            }
        };
        break;
    }
    return .{ .object = o };
}

/// All matches of all endpoints (and fragments), each tagged with its
/// endpoint and query offset, best (highest match_count) first. The sort is
/// stable: one endpoint's matches keep the core's order. At most
/// `max_matches` are kept per query offset.
fn querySummary(arena: std.mem.Allocator, results: []const Result, max_matches: ?usize) !Value {
    var matches: std.ArrayList(Value) = .empty;
    for (results) |r| {
        if (!r.ok()) continue;
        const queries = field(r.data, "queries") orelse continue;
        if (queries != .array) continue;
        for (queries.array.items) |q| {
            const list = field(q, "matches") orelse continue;
            if (list != .array) continue;
            for (list.array.items) |m| {
                if (m != .object) continue;
                var tagged: json.ObjectMap = .empty;
                try tagged.put(arena, "endpoint", .{ .string = r.endpoint });
                if (field(q, "query_offset")) |off| try tagged.put(arena, "query_offset", off);
                var it = m.object.iterator();
                while (it.next()) |e| try tagged.put(arena, e.key_ptr.*, e.value_ptr.*);
                try matches.append(arena, .{ .object = tagged });
            }
        }
    }
    std.mem.sort(Value, matches.items, {}, struct {
        fn better(_: void, a: Value, b: Value) bool {
            return (number(field(a, "match_count")) orelse 0) > (number(field(b, "match_count")) orelse 0);
        }
    }.better);

    if (max_matches) |max| {
        var per_query: std.StringHashMapUnmanaged(usize) = .empty;
        var kept: usize = 0;
        for (matches.items) |m| {
            const offset = field(m, "query_offset");
            const key = if (offset) |v| switch (v) {
                .number_string => |s| s,
                else => "",
            } else "";
            const count = try per_query.getOrPutValue(arena, key, 0);
            if (count.value_ptr.* >= max) continue;
            count.value_ptr.* += 1;
            matches.items[kept] = m;
            kept += 1;
        }
        matches.shrinkRetainingCapacity(kept);
    }

    var o: json.ObjectMap = .empty;
    try o.put(arena, "match_count", .{ .integer = @intCast(matches.items.len) });
    try o.put(arena, "matches", .{ .array = .{ .items = matches.items, .capacity = matches.capacity, .allocator = arena } });
    return .{ .object = o };
}

/// Totals over all databases.
fn statsSummary(arena: std.mem.Allocator, results: []const Result) !Value {
    var songs: f64 = 0;
    var duration: f64 = 0;
    var fingerprints: f64 = 0;
    for (results) |r| {
        if (!r.ok()) continue;
        songs += number(field(r.data, "song_count")) orelse 0;
        duration += number(field(r.data, "total_duration_seconds")) orelse 0;
        fingerprints += number(field(r.data, "total_fingerprints")) orelse 0;
    }
    var o: json.ObjectMap = .empty;
    try o.put(arena, "song_count", .{ .integer = @intFromFloat(songs) });
    try o.put(arena, "total_duration_seconds", try fixed(arena, duration));
    try o.put(arena, "total_fingerprints", .{ .integer = @intFromFloat(fingerprints) });
    try o.put(arena, "avg_fingerprints_per_second", try fixed(arena, if (duration > 0) fingerprints / duration else 0));
    return .{ .object = o };
}

/// "ok" when every endpoint is up, "degraded" when some are, else "down".
fn healthSummary(arena: std.mem.Allocator, results: []const Result) !Value {
    var n_ok: usize = 0;
    for (results) |r| n_ok += @intFromBool(r.ok());
    const s: []const u8 = if (results.len > 0 and n_ok == results.len) "ok" else if (n_ok > 0) "degraded" else "down";
    var o: json.ObjectMap = .empty;
    try o.put(arena, "status", .{ .string = s });
    try o.put(arena, "endpoints_ok", .{ .integer = @intCast(n_ok) });
    try o.put(arena, "endpoints_total", .{ .integer = @intCast(results.len) });
    return .{ .object = o };
}

fn field(v: ?Value, name: []const u8) ?Value {
    const obj = v orelse return null;
    if (obj != .object) return null;
    return obj.object.get(name);
}

/// A JSON number in any of its parsed forms.
pub fn number(v: ?Value) ?f64 {
    return switch (v orelse return null) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

/// A number with three decimals, like the CLI's JSON.
pub fn fixed(arena: std.mem.Allocator, x: f64) !Value {
    return .{ .number_string = try std.fmt.allocPrint(arena, "{d:.3}", .{x}) };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn testData(arena: std.mem.Allocator, text: []const u8) !Value {
    return json.parseFromSliceLeaky(Value, arena, text, parse_options);
}

test "query summary merges and sorts matches of all endpoints" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const results = [_]Result{
        .{ .endpoint = "http://a", .status = 200, .data = try testData(arena,
            \\{"queries":[{"query_offset":0.000,"matches":[{"match_count":7,"path":"x"}]}]}
        ) },
        .failure("http://b", 502, "connection refused"),
        .{ .endpoint = "http://c", .status = 200, .data = try testData(arena,
            \\{"queries":[{"query_offset":30.000,"matches":[{"match_count":12,"path":"y"},{"match_count":3,"path":"z"}]}]}
        ) },
    };
    var out: Io.Writer.Allocating = .init(arena);
    try write(&out.writer, arena, .query, &results, .{});
    try std.testing.expectEqual(@as(u16, 200), status(&results));

    const env = try testData(arena, out.written());
    try std.testing.expectEqual(true, env.object.get("ok").?.bool);
    try std.testing.expectEqualStrings("3", env.object.get("endpoint_count").?.number_string);
    const matches = env.object.get("summary").?.object.get("matches").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), matches.len);
    try std.testing.expectEqualStrings("y", matches[0].object.get("path").?.string);
    try std.testing.expectEqualStrings("http://c", matches[0].object.get("endpoint").?.string);
    try std.testing.expectEqualStrings("30.000", matches[0].object.get("query_offset").?.number_string);
    try std.testing.expectEqualStrings("z", matches[2].object.get("path").?.string);

    // A load balancer reads the envelope back: failures and numbers survive.
    var msg: ?[]const u8 = null;
    var back_summary: ?Value = null;
    const back = try parse(arena, out.written(), &msg, &back_summary);
    try std.testing.expectEqual(@as(usize, 3), back_summary.?.object.get("matches").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 3), back.len);
    try std.testing.expect(!back[1].ok());
    try std.testing.expectEqual(@as(u16, 502), back[1].status);
    try std.testing.expectEqualStrings("30.000", field(back[2].data.?.object.get("queries").?.array.items[0], "query_offset").?.number_string);
}

test "query summary keeps at most max_matches per query offset" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const results = [_]Result{
        .{ .endpoint = "http://a", .status = 200, .data = try testData(arena,
            \\{"queries":[{"query_offset":0.000,"matches":[{"match_count":9},{"match_count":5}]},{"query_offset":30.000,"matches":[{"match_count":8}]}]}
        ) },
        .{ .endpoint = "http://b", .status = 200, .data = try testData(arena,
            \\{"queries":[{"query_offset":0.000,"matches":[{"match_count":7},{"match_count":6}]},{"query_offset":30.000,"matches":[{"match_count":1}]}]}
        ) },
    };
    const s = (try summary(arena, .query, &results, .{ .max_matches = 2 })).object;
    const matches = s.get("matches").?.array.items;
    try std.testing.expectEqual(@as(usize, 4), matches.len);
    // 0.000: 9 (a), 7 (b); 30.000: 8 (a), 1 (b); dropped 6 and 5.
    try std.testing.expectEqualStrings("9", matches[0].object.get("match_count").?.number_string);
    try std.testing.expectEqualStrings("8", matches[1].object.get("match_count").?.number_string);
    try std.testing.expectEqualStrings("7", matches[2].object.get("match_count").?.number_string);
    try std.testing.expectEqualStrings("1", matches[3].object.get("match_count").?.number_string);
}

test "stats and health summaries" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const results = [_]Result{
        .{ .endpoint = "a", .status = 200, .data = try testData(arena,
            \\{"song_count":2,"total_duration_seconds":100.5,"total_fingerprints":1000}
        ) },
        .{ .endpoint = "b", .status = 200, .data = try testData(arena,
            \\{"song_count":3,"total_duration_seconds":99.5,"total_fingerprints":3000}
        ) },
        .failure("c", 502, "down"),
    };
    const s = (try summary(arena, .stats, &results, .{})).object;
    try std.testing.expectEqual(@as(i64, 5), s.get("song_count").?.integer);
    try std.testing.expectEqualStrings("200.000", s.get("total_duration_seconds").?.number_string);
    try std.testing.expectEqualStrings("20.000", s.get("avg_fingerprints_per_second").?.number_string);

    try std.testing.expectEqualStrings("degraded", (try summary(arena, .health, &results, .{})).object.get("status").?.string);
    try std.testing.expectEqualStrings("ok", (try summary(arena, .health, results[0..2], .{})).object.get("status").?.string);
    try std.testing.expectEqualStrings("down", (try summary(arena, .health, results[2..], .{})).object.get("status").?.string);
    try std.testing.expectEqual(@as(u16, 502), status(results[2..]));
}

test "error envelope has no results" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: Io.Writer.Allocating = .init(arena);
    try writeError(&out.writer, "needs an identifier");
    var msg: ?[]const u8 = null;
    const results = try parse(arena, out.written(), &msg, null);
    try std.testing.expectEqual(@as(usize, 0), results.len);
    try std.testing.expectEqualStrings("needs an identifier", msg.?);
}
