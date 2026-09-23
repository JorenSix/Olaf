//! Every record the CLI prints, in one place: store summaries and skip
//! records (stderr), query result rows and query JSON objects (stdout), plus
//! the shared CSV / JSON escaping.
const std = @import("std");
const Io = std.Io;

const c = @import("olaf_cli_core.zig").c;
const olaf_cli_util = @import("olaf_cli_util.zig");

pub const StoreFormat = enum { human, csv, json };
pub const OutputFormat = enum { csv, json };

pub const store_csv_header = "action,file_index,file_total,audio_identifier,internal_id,fingerprints,audio_seconds,cpu_seconds,fingerprints_per_second,realtime_factor\n";

pub const query_csv_header = "query_index, total_queries, query_path, query_offset, match_count, query_start, query_stop, path, match_identifier, reference_start, reference_stop\n";

/// RFC 4180-style field: quoted only when it contains a comma, quote or line
/// break, with embedded quotes doubled.
pub fn csvField(w: *Io.Writer, s: []const u8) !void {
    if (std.mem.indexOfAny(u8, s, ",\"\r\n") == null) return w.writeAll(s);
    try w.writeByte('"');
    for (s) |ch| {
        if (ch == '"') try w.writeByte('"');
        try w.writeByte(ch);
    }
    try w.writeByte('"');
}

pub fn jsonString(w: *Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0x08 => try w.writeAll("\\b"),
        0x0C => try w.writeAll("\\f"),
        else => if (ch < 0x20) try w.print("\\u{x:0>4}", .{ch}) else try w.writeByte(ch),
    };
    try w.writeByte('"');
}

/// Format a float with libc printf semantics ("%.3f"). Query output has
/// always been printed by C printf; this keeps its rounding byte-identical.
fn cFloat(w: *Io.Writer, comptime fmt: [:0]const u8, value: f64) !void {
    var buf: [64]u8 = undefined;
    const n = c.snprintf(&buf, buf.len, fmt.ptr, value);
    try w.writeAll(buf[0..@intCast(n)]);
}

/// Write `bytes` in one call: to stderr (store records) with the Zig writer,
/// or to libc stdout (query output), which the core also prints its result
/// header to, so header and rows stay in order.
fn emitStderr(bytes: []const u8) !void {
    try Io.File.stderr().writeStreamingAll(olaf_cli_util.defaultIo(), bytes);
}

fn emitStdout(bytes: []const u8) void {
    _ = c.fwrite(bytes.ptr, 1, bytes.len, cStdout());
}

/// libc's `stdout`: an inline function in the macOS headers, a variable in
/// glibc/musl.
fn cStdout() *c.FILE {
    const f: ?*c.FILE = if (@typeInfo(@TypeOf(c.stdout)) == .@"fn") c.stdout() else c.stdout;
    return f.?;
}

// ---------------------------------------------------------------------------
// Store records (stderr)
// ---------------------------------------------------------------------------

pub const StoreSummary = struct {
    index: usize,
    total: usize,
    audio_identifier: []const u8,
    internal_id: u32,
    fingerprints: usize,
    audio_seconds: f64,
    cpu_seconds: f64,
};

pub fn writeStoreSummary(format: StoreFormat, s: StoreSummary) !void {
    const file_index = s.index + 1; // user-facing index is 1-based
    const fp_per_second: f64 = if (s.audio_seconds > 0.0) @as(f64, @floatFromInt(s.fingerprints)) / s.audio_seconds else 0.0;
    const realtime_factor: f64 = if (s.cpu_seconds > 0.0) s.audio_seconds / s.cpu_seconds else 0.0;

    var buf: [4096]u8 = undefined;
    var fbs = Io.Writer.fixed(&buf);
    const w = &fbs;

    switch (format) {
        .human => {
            // Zero-pad the index to the width of `total`: "01/35", but "1/7".
            var idx_buf: [32]u8 = undefined;
            const idx_str = try std.fmt.bufPrint(&idx_buf, "{d}", .{file_index});
            var total_buf: [32]u8 = undefined;
            const width = (try std.fmt.bufPrint(&total_buf, "{d}", .{s.total})).len;
            try w.splatByteAll('0', width -| idx_str.len);
            try w.writeAll(idx_str);
            try w.print("/{d} Stored {d} fp's from {d:.1}s ({d:.0} fp/s) in {d:.3}s ({d:.0} times realtime)\n", .{
                s.total, s.fingerprints, s.audio_seconds, fp_per_second, s.cpu_seconds, realtime_factor,
            });
        },
        .csv => {
            try w.print("store,{d},{d},", .{ file_index, s.total });
            try csvField(w, s.audio_identifier);
            try w.print(",{d},{d},{d:.1},{d:.3},{d:.1},{d:.0}\n", .{
                s.internal_id, s.fingerprints, s.audio_seconds, s.cpu_seconds, fp_per_second, realtime_factor,
            });
        },
        .json => {
            try w.print("{{\"action\":\"store\",\"file_index\":{d},\"file_total\":{d},\"audio_identifier\":", .{ file_index, s.total });
            try jsonString(w, s.audio_identifier);
            try w.print(",\"internal_id\":{d},\"fingerprints\":{d},\"audio_seconds\":{d:.1},\"cpu_seconds\":{d:.3},\"fingerprints_per_second\":{d:.1},\"realtime_factor\":{d:.0}}}\n", .{
                s.internal_id, s.fingerprints, s.audio_seconds, s.cpu_seconds, fp_per_second, realtime_factor,
            });
        },
    }
    // One write per record: POSIX keeps writes <= PIPE_BUF atomic, so
    // threaded workers don't interleave bytes mid-record.
    try emitStderr(fbs.buffered());
}

/// "Skipped, already indexed" record. CSV rows keep the store_csv_header
/// column count with empty numeric fields.
pub fn writeStoreSkip(format: StoreFormat, audio_identifier: []const u8, internal_id: u32) !void {
    var buf: [4096]u8 = undefined;
    var fbs = Io.Writer.fixed(&buf);
    const w = &fbs;
    switch (format) {
        .human => try w.print("Skipped (already indexed, use -f to re-store): {s}\n", .{audio_identifier}),
        .csv => {
            try w.writeAll("skip,,,");
            try csvField(w, audio_identifier);
            try w.print(",{d},,,,,\n", .{internal_id});
        },
        .json => {
            try w.writeAll("{\"action\":\"skip\",\"audio_identifier\":");
            try jsonString(w, audio_identifier);
            try w.print(",\"internal_id\":{d}}}\n", .{internal_id});
        },
    }
    try emitStderr(fbs.buffered());
}

// ---------------------------------------------------------------------------
// Query output (stdout)
// ---------------------------------------------------------------------------

/// One match reported by the core's result callback. `path` is only valid
/// during the callback unless copied.
pub const Match = struct {
    match_count: i32,
    query_start: f32,
    query_stop: f32,
    path: []const u8,
    match_identifier: u32,
    reference_start: f32,
    reference_stop: f32,
};

/// Which query a row belongs to (the first four CSV columns).
pub const QueryInfo = struct {
    index: usize,
    total: usize,
    path: []const u8,
    offset: f32,
};

/// One CSV result row:
/// "1 ,2 ,query, 0.000, 12 ,1.936 ,19.304, ref, 3517681762, 70.864, 88.232"
pub fn writeMatchRow(q: QueryInfo, m: Match) void {
    var buf: [4096]u8 = undefined;
    var fbs = Io.Writer.fixed(&buf);
    formatMatchRow(&fbs, q, m) catch return; // a >4k path: the row is dropped, as before truncation
    emitStdout(fbs.buffered());
}

fn formatMatchRow(w: *Io.Writer, q: QueryInfo, m: Match) !void {
    try w.print("{d} ,{d} ,", .{ q.index + 1, q.total });
    try csvField(w, q.path);
    try w.writeAll(", ");
    try cFloat(w, "%.3f", q.offset);
    try w.print(", {d} ,", .{m.match_count});
    try cFloat(w, "%.3f", m.query_start);
    try w.writeAll(" ,");
    try cFloat(w, "%.3f", m.query_stop);
    try w.writeAll(", ");
    try csvField(w, m.path);
    try w.print(", {d}, ", .{m.match_identifier});
    try cFloat(w, "%.3f", m.reference_start);
    try w.writeAll(", ");
    try cFloat(w, "%.3f", m.reference_stop);
    try w.writeAll("\n");
}

pub const QueryStats = struct {
    fingerprints: usize,
    audio_seconds: f64,
    cpu_seconds: f64,
};

/// One pretty-printed JSON object per query (not NDJSON: callers that
/// concatenate queries see a stream of objects).
pub fn writeQueryJson(allocator: std.mem.Allocator, q: QueryInfo, stats: QueryStats, matches: []const Match) !void {
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;

    const fp_per_second: f64 = if (stats.audio_seconds > 0.0) @as(f64, @floatFromInt(stats.fingerprints)) / stats.audio_seconds else 0.0;
    const realtime_factor: f64 = if (stats.cpu_seconds > 0.0) stats.audio_seconds / stats.cpu_seconds else 0.0;

    try w.print("{{\n  \"query_index\": {d},\n  \"total_queries\": {d},\n  \"query_path\": ", .{ q.index + 1, q.total });
    try jsonString(w, q.path);
    try w.writeAll(",\n  \"query_offset\": ");
    try cFloat(w, "%.3f", q.offset);
    try w.print(",\n  \"fingerprints_matched\": {d},\n  \"query_duration_seconds\": ", .{stats.fingerprints});
    try cFloat(w, "%.3f", stats.audio_seconds);
    try w.writeAll(",\n  \"fingerprints_per_second\": ");
    try cFloat(w, "%.3f", fp_per_second);
    try w.writeAll(",\n  \"search_time_seconds\": ");
    try cFloat(w, "%.3f", stats.cpu_seconds);
    try w.writeAll(",\n  \"realtime_factor\": ");
    try cFloat(w, "%.3f", realtime_factor);
    try w.writeAll(",\n  \"matches\": [");
    for (matches, 0..) |m, i| {
        try w.print("{s}\n    {{\n      \"match_count\": {d},\n      \"query_start\": ", .{ if (i == 0) "" else ",", m.match_count });
        try cFloat(w, "%.3f", m.query_start);
        try w.writeAll(",\n      \"query_stop\": ");
        try cFloat(w, "%.3f", m.query_stop);
        try w.writeAll(",\n      \"path\": ");
        try jsonString(w, m.path);
        try w.print(",\n      \"match_identifier\": {d},\n      \"reference_start\": ", .{m.match_identifier});
        try cFloat(w, "%.3f", m.reference_start);
        try w.writeAll(",\n      \"reference_stop\": ");
        try cFloat(w, "%.3f", m.reference_stop);
        try w.writeAll("\n    }");
    }
    if (matches.len > 0) try w.writeAll("\n  ");
    try w.writeAll("]\n}\n");
    emitStdout(out.written());
}
