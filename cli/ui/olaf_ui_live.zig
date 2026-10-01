//! Live UI transport and recent-first matching. No core or CLI imports.
const std = @import("std");
const Io = std.Io;
const rest = @import("olaf_rest");
const V = std.json.Value;
const A = std.mem.Allocator;
pub const html = @embedFile("olaf_ui_live.html");
const headers = [_]std.http.Header{ .{ .name = "content-type", .value = "application/json" }, .{ .name = "cache-control", .value = "no-store" } };

pub fn isPath(path: []const u8) bool {
    return std.mem.eql(u8, std.mem.trimEnd(u8, path, "/"), "/ui_live");
}
const Ids = struct { session: []const u8 = "", request: []const u8 = "" };
fn respond(req: *std.http.Server.Request, arena: A, status: std.http.Status, ids: Ids, data: V, message: ?[]const u8, keep: bool) !bool {
    var out: Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(.{ .session_id = ids.session, .request_id = ids.request, .data = data, .@"error" = message }, .{}, &out.writer);
    try req.respond(out.written(), .{ .status = status, .extra_headers = &headers, .keep_alive = keep });
    return keep and req.head.keep_alive;
}
pub fn handle(req: *std.http.Server.Request, arena: A, io: Io, backend: rest.Backend, workers: *Io.Semaphore, max_bytes: usize) !bool {
    if (req.head.method == .GET or req.head.method == .HEAD) {
        try req.respond(html, .{ .extra_headers = &.{ .{ .name = "content-type", .value = "text/html; charset=utf-8" }, .{ .name = "cache-control", .value = "no-store" } }, .keep_alive = true });
        return req.head.keep_alive;
    }
    var ids: Ids = .{};
    var it = req.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "x-olaf-session")) ids.session = try arena.dupe(u8, h.value);
        if (std.ascii.eqlIgnoreCase(h.name, "x-olaf-request")) ids.request = try arena.dupe(u8, h.value);
    }
    if (req.head.method != .POST) return respond(req, arena, .method_not_allowed, ids, .null, "use GET or POST", false);
    const media = req.head.content_type orelse "";
    if (!std.ascii.eqlIgnoreCase(media, "audio/wav")) return respond(req, arena, .unsupported_media_type, ids, .null, "send mono PCM16 audio/wav", false);
    const limit = @min(max_bytes, 44 + 192000 * 15 * 2);
    if (req.head.content_length) |n| if (n > limit) return respond(req, arena, .payload_too_large, ids, .null, "live window is too large", false);
    var buf: [8192]u8 = undefined;
    const reader = try req.readerExpectContinue(&buf);
    const body = reader.allocRemaining(arena, .limited(limit)) catch return respond(req, arena, .payload_too_large, ids, .null, "could not read live window within limit", false);
    const wav = Wav.parse(body) catch return respond(req, arena, .bad_request, ids, .null, "expected a standard mono PCM16 WAV window of at most 15 seconds", true);
    workers.waitUncancelable(io);
    defer workers.post(io);
    const data = answer(arena, io, backend, wav) catch |err| return respond(req, arena, .unprocessable_entity, ids, .null, @errorName(err), true);
    return respond(req, arena, .ok, ids, data, null, true);
}

pub const Wav = struct {
    bytes: []const u8,
    rate: u32,
    frames: usize,
    pub fn parse(b: []const u8) !Wav {
        if (b.len < 46 or !std.mem.eql(u8, b[0..4], "RIFF") or !std.mem.eql(u8, b[8..16], "WAVEfmt ") or !std.mem.eql(u8, b[36..40], "data")) return error.InvalidWav;
        const rate = std.mem.readInt(u32, b[24..28], .little);
        if (rate < 8000 or rate > 192000 or std.mem.readInt(u32, b[4..8], .little) != b.len - 8 or
            std.mem.readInt(u32, b[16..20], .little) != 16 or std.mem.readInt(u16, b[20..22], .little) != 1 or
            std.mem.readInt(u16, b[22..24], .little) != 1 or std.mem.readInt(u32, b[28..32], .little) != rate * 2 or
            std.mem.readInt(u16, b[32..34], .little) != 2 or std.mem.readInt(u16, b[34..36], .little) != 16 or
            std.mem.readInt(u32, b[40..44], .little) != b.len - 44 or (b.len - 44) % 2 != 0) return error.InvalidWav;
        const frames = (b.len - 44) / 2;
        if (frames > rate * 15) return error.InvalidWav;
        return .{ .bytes = b, .rate = rate, .frames = frames };
    }
    fn duration(self: Wav) f64 {
        return @as(f64, @floatFromInt(self.frames)) / @as(f64, @floatFromInt(self.rate));
    }
    fn tail(self: Wav, a: A) !Wav {
        const frames = @min(self.frames, self.rate * 5);
        const b = try a.alloc(u8, 44 + frames * 2);
        @memcpy(b[0..44], self.bytes[0..44]);
        @memcpy(b[44..], self.bytes[self.bytes.len - frames * 2 ..]);
        std.mem.writeInt(u32, b[4..8], @intCast(b.len - 8), .little);
        std.mem.writeInt(u32, b[40..44], @intCast(b.len - 44), .little);
        return try parse(b);
    }
};
fn num(m: V, key: []const u8) f64 {
    return rest.envelope.number(m.object.get(key)) orelse 0;
}
fn offset(m: V) f64 {
    return num(m, "reference_start") - num(m, "query_start");
}
fn recent(m: V) bool {
    return m.object.get("recent").?.bool;
}
fn before(_: void, a: V, b: V) bool {
    if (recent(a) != recent(b)) return recent(a);
    if (num(a, "match_count") != num(b, "match_count")) return num(a, "match_count") > num(b, "match_count");
    return num(a, "query_stop") > num(b, "query_stop");
}
fn collect(a: A, list: *std.array_list.Managed(V), matches: V, shift: f64, fresh: bool) !void {
    for (matches.array.items) |item| {
        var m = item;
        const start = rest.envelope.number(m.object.get("query_start")) orelse continue;
        const stop = rest.envelope.number(m.object.get("query_stop")) orelse continue;
        if (!std.math.isFinite(start) or !std.math.isFinite(stop) or stop - start < 0.75) continue;
        try m.object.put(a, "query_start", .{ .float = start + shift });
        try m.object.put(a, "query_stop", .{ .float = stop + shift });
        try m.object.put(a, "recent", .{ .bool = fresh });
        try list.append(m);
    }
}
fn query(a: A, io: Io, backend: rest.Backend, bytes: []const u8) !V {
    const results = try backend.handle(a, io, .{ .endpoint = .query, .params = .{ .identifier = "live.wav" }, .raw_query = "", .body = bytes });
    if (results.len == 0 or results[0].err != null or results[0].data == null) return error.QueryFailed;
    return results[0].data.?.object.get("queries").?.array.items[0].object.get("matches").?;
}
fn ranked(a: A, tail_matches: V, full_matches: V, shift: f64) !V {
    var all: std.array_list.Managed(V) = .init(a);
    try collect(a, &all, tail_matches, shift, true);
    try collect(a, &all, full_matches, 0, false);
    std.mem.sort(V, all.items, {}, before);
    var kept: std.array_list.Managed(V) = .init(a);
    for (all.items) |m| {
        var duplicate = false;
        for (kept.items) |k| {
            if (num(k, "match_identifier") == num(m, "match_identifier") and @abs(offset(k) - offset(m)) <= 0.25) {
                duplicate = true;
                break;
            }
        }
        if (!duplicate) try kept.append(m);
    }
    return .{ .array = kept };
}
fn answer(a: A, io: Io, backend: rest.Backend, wav: Wav) !V {
    const tail = try wav.tail(a);
    const newest = try query(a, io, backend, tail.bytes);
    const full = if (wav.frames > tail.frames) try query(a, io, backend, wav.bytes) else V{ .array = .init(a) };
    var matches = try ranked(a, newest, full, wav.duration() - tail.duration());
    if (matches.array.items.len > 0) {
        var m = &matches.array.items[0];
        const position = offset(m.*) + wav.duration();
        const bounds = clipBounds(position);
        const start = bounds.start;
        try m.object.put(a, "reference_at_end", .{ .float = position });
        try m.object.put(a, "clip_start", .{ .float = start });
        const path = m.object.get("path").?.string;
        const audio = cut(a, io, path, start, bounds.duration) catch null;
        if (audio) |bytes| {
            const enc = std.base64.standard.Encoder;
            try m.object.put(a, "audio", .{ .string = enc.encode(try a.alloc(u8, enc.calcSize(bytes.len)), bytes) });
            // ffmpeg emits a WAV with extra chunks; count its PCM data separately.
            try m.object.put(a, "clip_duration", .{ .float = try pcmDuration(bytes) });
        } else {
            try m.object.put(a, "audio", .null);
            try m.object.put(a, "audio_error", .{ .string = "Reference audio is unavailable" });
        }
    }
    var data: std.json.ObjectMap = .empty;
    try data.put(a, "query_duration", .{ .float = wav.duration() });
    try data.put(a, "matches", matches);
    try data.put(a, "selected_index", if (matches.array.items.len > 0) .{ .integer = 0 } else .null);
    return .{ .object = data };
}
fn clipBounds(position: f64) struct { start: f64, duration: f64 } {
    const start = @max(0, position - 5);
    return .{ .start = start, .duration = @max(0, position + 25 - start) };
}

test "live clip boundaries cover five seconds before and 25 after" {
    try std.testing.expectEqual(@as(f64, 0), clipBounds(2).start);
    try std.testing.expectEqual(@as(f64, 27), clipBounds(2).duration);
    try std.testing.expectEqual(@as(f64, 15), clipBounds(20).start);
    try std.testing.expectEqual(@as(f64, 30), clipBounds(20).duration);
    try std.testing.expectEqual(@as(f64, 0), clipBounds(-30).duration);
}

fn cut(a: A, io: Io, path: []const u8, start: f64, duration: f64) ![]const u8 {
    if (duration <= 0) return error.NoAudio;
    const r = try std.process.run(a, io, .{ .argv = &.{ "ffmpeg", "-v", "error", "-nostdin", "-ss", try std.fmt.allocPrint(a, "{d:.6}", .{start}), "-i", path, "-t", try std.fmt.allocPrint(a, "{d:.6}", .{duration}), "-vn", "-ac", "2", "-ar", "44100", "-c:a", "pcm_s16le", "-f", "wav", "pipe:1" } });
    if (r.term != .exited or r.term.exited != 0 or r.stdout.len == 0) return error.NoAudio;
    _ = try pcmDuration(r.stdout);
    return r.stdout;
}
fn pcmDuration(b: []const u8) !f64 {
    var pos: usize = 12;
    while (pos + 8 <= b.len) {
        const n = std.mem.readInt(u32, b[pos + 4 ..][0..4], .little);
        if (std.mem.eql(u8, b[pos..][0..4], "data")) return @as(f64, @floatFromInt(@min(n, b.len - pos - 8))) / (44100.0 * 4);
        if (n > b.len - pos - 8) break;
        pos += 8 + n + n % 2;
    }
    return error.NoAudio;
}

test "live ranking prefers recent evidence and merges only aligned duplicates" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = try std.json.parseFromSlice(V, a, "[{\"match_identifier\":2,\"match_count\":6,\"query_start\":0,\"query_stop\":0.75,\"reference_start\":30},{\"match_identifier\":3,\"query_start\":0,\"query_stop\":0.749}]", .{});
    const f = try std.json.parseFromSlice(V, a, "[{\"match_identifier\":1,\"match_count\":100,\"query_start\":0,\"query_stop\":9,\"reference_start\":0},{\"match_identifier\":2,\"match_count\":50,\"query_start\":10,\"query_stop\":14,\"reference_start\":30}]", .{});
    const result = try ranked(a, t.value, f.value, 10);
    try std.testing.expectEqual(@as(usize, 2), result.array.items.len);
    try std.testing.expectEqual(@as(f64, 2), num(result.array.items[0], "match_identifier"));
    try std.testing.expectEqual(@as(f64, 10), num(result.array.items[0], "query_start"));
    try std.testing.expectEqual(@as(f64, 20), offset(result.array.items[0]));
}

test "live WAV validation, duration and exact recent tail" {
    const a = std.testing.allocator;
    const b = try a.alloc(u8, 44 + 8000 * 15 * 2);
    defer a.free(b);
    @memset(b, 0);
    @memcpy(b[0..4], "RIFF");
    @memcpy(b[8..16], "WAVEfmt ");
    @memcpy(b[36..40], "data");
    std.mem.writeInt(u32, b[4..8], @intCast(b.len - 8), .little);
    std.mem.writeInt(u32, b[16..20], 16, .little);
    std.mem.writeInt(u16, b[20..22], 1, .little);
    std.mem.writeInt(u16, b[22..24], 1, .little);
    std.mem.writeInt(u32, b[24..28], 8000, .little);
    std.mem.writeInt(u32, b[28..32], 16000, .little);
    std.mem.writeInt(u16, b[32..34], 2, .little);
    std.mem.writeInt(u16, b[34..36], 16, .little);
    std.mem.writeInt(u32, b[40..44], @intCast(b.len - 44), .little);
    b[b.len - 1] = 77;
    const w = try Wav.parse(b);
    try std.testing.expectEqual(@as(f64, 15), w.duration());
    const t = try w.tail(a);
    defer a.free(t.bytes);
    try std.testing.expectEqual(@as(f64, 5), t.duration());
    try std.testing.expectEqualSlices(u8, b[b.len - 80000 ..], t.bytes[44..]);
    try std.testing.expectError(error.InvalidWav, Wav.parse(b[0 .. b.len - 1]));
    b[22] = 2;
    try std.testing.expectError(error.InvalidWav, Wav.parse(b));
    b[22] = 1;
    b[34] = 32;
    try std.testing.expectError(error.InvalidWav, Wav.parse(b));
    try std.testing.expect(isPath("/ui_live/"));
    try std.testing.expect(!isPath("/ui_lively"));
}
