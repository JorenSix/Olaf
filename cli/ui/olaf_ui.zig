//! Optional web page for `olaf rest serve` (config `rest_ui`, off by
//! default), plugged into the REST server as a `rest.server.Extension`; the
//! API itself does not know about it.
//!
//!   GET  /ui   the upload form (olaf_ui_upload.html)
//!   POST /ui   multipart/form-data with the audio in field "audio": queries
//!              it like /api/query and answers one self-contained results
//!              page (olaf_ui_results.html) with the query object and, for
//!              the query and every match, a stereo MP3 clip (base64) aligned
//!              to the query start, so the page plays both in sync without
//!              fetching anything else.
//!
//! Clips are cut with ffmpeg from the uploaded file and from the reference
//! paths the query reports (the database metadata, never the client).
const std = @import("std");
const Io = std.Io;
const http = std.http;
const json = std.json;
const Value = json.Value;
const rest = @import("olaf_rest");
const envelope = rest.envelope;

const log = std.log.scoped(.olaf_rest);

pub const upload_html = @embedFile("olaf_ui_upload.html");
pub const results_html = @embedFile("olaf_ui_results.html");

/// Replaced by the page data in results_html (a JSON string, so the
/// unrendered template is still valid).
pub const placeholder = "\"__OLAF_DATA__\"";

comptime {
    @setEvalBranchQuota(10 * results_html.len);
    if (std.mem.count(u8, results_html, placeholder) != 1) @compileError("olaf_ui_results.html needs the data placeholder exactly once");
}

const html_headers = [_]http.Header{
    .{ .name = "content-type", .value = "text/html; charset=utf-8" },
    // Results pages carry the audio; do not keep them around.
    .{ .name = "cache-control", .value = "no-store" },
};

pub const Options = struct {
    /// How many /ui requests cut clips at the same time (rest_workers).
    workers: u32,
    /// Where the upload is written for ffmpeg while its clip is cut.
    temp_dir: []const u8,
};

const Ui = struct {
    backend: rest.Backend,
    max_body_bytes: usize,
    log_label: []const u8,
    workers: Io.Semaphore,
    temp_dir: []const u8,
};

var upload_counter: std.atomic.Value(u64) = .init(0);

/// The /ui extension for a server with `serve_opts`, answering queries with
/// `backend` (allocated in `arena`, which must outlive the server).
pub fn extension(arena: std.mem.Allocator, backend: rest.Backend, serve_opts: rest.ServeOptions, opts: Options) !rest.server.Extension {
    const ui = try arena.create(Ui);
    ui.* = .{
        .backend = backend,
        .max_body_bytes = serve_opts.max_body_bytes,
        .log_label = serve_opts.log_label,
        .workers = .{ .permits = opts.workers },
        .temp_dir = opts.temp_dir,
    };
    return .{ .ctx = ui, .handleFn = handle };
}

/// True for the /ui path (a trailing slash is ignored).
pub fn isUiPath(path: []const u8) bool {
    return std.mem.eql(u8, std.mem.trimEnd(u8, path, "/"), "/ui");
}

fn handle(ctx: *anyopaque, arena: std.mem.Allocator, io: Io, request: *http.Server.Request) anyerror!?bool {
    const target = request.head.target;
    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
    if (!isUiPath(path)) return null;
    const self: *Ui = @ptrCast(@alignCast(ctx));
    const start = Io.Clock.awake.now(io);

    const method = request.head.method;
    if (method == .GET or method == .HEAD) {
        try request.respond(upload_html, .{ .keep_alive = true, .extra_headers = &html_headers });
        return request.head.keep_alive;
    }
    if (method != .POST) {
        // Any body is not read: close the connection.
        try request.respond("/ui expects GET or POST\n", .{ .status = .method_not_allowed, .keep_alive = false });
        return false;
    }

    // The head's strings are invalidated once the body is read.
    const content_type: ?[]const u8 = if (request.head.content_type) |ct| try arena.dupe(u8, ct) else null;
    const too_large = try std.fmt.allocPrint(arena, "the upload is larger than rest_max_body_mb ({d} bytes)", .{self.max_body_bytes});
    if (request.head.content_length) |len| if (len > self.max_body_bytes) {
        return try respondPage(request, try errorPage(arena, .payload_too_large, too_large), false);
    };
    var transfer_buf: [8192]u8 = undefined;
    const reader = request.readerExpectContinue(&transfer_buf) catch return false;
    const body = reader.allocRemaining(arena, .limited(self.max_body_bytes)) catch |err| switch (err) {
        // Chunked upload over the limit: the rest is not read.
        error.StreamTooLong => return try respondPage(request, try errorPage(arena, .payload_too_large, too_large), false),
        else => return false,
    };

    const page = try answer(self, arena, io, content_type, body);
    const keep = try respondPage(request, page, true);

    const ms = start.durationTo(Io.Clock.awake.now(io)).toMilliseconds();
    log.info("{s}POST /ui {d} KB -> {d} in {d} ms: {s}", .{ self.log_label, (body.len + 1023) / 1024, @intFromEnum(page.status), ms, page.summary });
    return keep;
}

fn respondPage(request: *http.Server.Request, page: Page, keep_alive: bool) !bool {
    try request.respond(page.html, .{ .status = page.status, .keep_alive = keep_alive, .extra_headers = &html_headers });
    return keep_alive and request.head.keep_alive;
}

/// A rendered page and the summary its request is logged with.
pub const Page = struct {
    status: http.Status,
    html: []const u8,
    summary: []const u8,
};

/// Query the uploaded file and render the results page. Failures render
/// the same page with an error message.
fn answer(self: *Ui, arena: std.mem.Allocator, io: Io, content_type: ?[]const u8, body: []const u8) !Page {
    const boundary = boundaryOf(content_type orelse "") orelse
        return errorPage(arena, .bad_request, "send the audio as multipart/form-data (field \"audio\")");
    const file = filePart(body, boundary, "audio") catch
        return errorPage(arena, .bad_request, "no audio file in the upload");
    if (file.data.len == 0) return errorPage(arena, .bad_request, "the uploaded file is empty");
    const name = if (file.filename.len > 0) file.filename else "upload";

    const results = self.backend.handle(arena, io, .{
        .endpoint = .query,
        .params = .{ .identifier = name },
        .raw_query = "",
        .body = file.data,
    }) catch |err| return errorPage(arena, .internal_server_error, @errorName(err));
    const r = results[0];
    if (r.err) |message| return errorPage(arena, @enumFromInt(r.status), message);

    var q = r.data.?.object.get("queries").?.array.items[0];
    const duration = envelope.number(q.object.get("query_duration_seconds_exact")) orelse
        envelope.number(q.object.get("query_duration_seconds")) orelse 0;
    // The matches go in the page once, next to the query (the clips are large).
    const matches_value = q.object.get("matches").?;
    _ = q.object.orderedRemove("matches");
    const matches = matches_value.array.items;
    try q.object.put(arena, "name", .{ .string = name });
    try q.object.put(arena, "duration", try envelope.fixed(arena, duration));

    self.workers.waitUncancelable(io);
    defer self.workers.post(io);

    var data: json.ObjectMap = .empty;
    try data.put(arena, "query", q);
    try data.put(arena, "query_audio", try uploadClip(self, arena, io, file.data, duration));
    for (matches) |*m| try addClip(arena, io, m, duration);
    try data.put(arena, "matches", matches_value);
    try data.put(arena, "error", .null);

    const summary = try std.fmt.allocPrint(arena, "{d} match{s}", .{ matches.len, if (matches.len == 1) "" else "es" });
    return .{ .status = .ok, .html = try render(arena, .{ .object = data }), .summary = summary };
}

/// The whole upload as a clip (base64), or null when ffmpeg fails.
fn uploadClip(self: *Ui, arena: std.mem.Allocator, io: Io, upload: []const u8, duration: f64) !Value {
    Io.Dir.cwd().createDirPath(io, self.temp_dir) catch |e| if (e != error.PathAlreadyExists) return e;
    const path = try std.fmt.allocPrint(arena, "{s}/olaf_ui_{d}_{d}.upload", .{ self.temp_dir, std.Thread.getCurrentId(), upload_counter.fetchAdd(1, .monotonic) });
    defer Io.Dir.cwd().deleteFile(io, path) catch {};
    {
        const f = try Io.Dir.cwd().createFile(io, path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, upload);
    }
    const mp3 = clip(arena, io, path, 0, duration) catch return .null;
    return .{ .string = try base64(arena, mp3) };
}

/// Add the match's clip, aligned to the query start: the reference from
/// reference_start - query_start for the query duration, preceded by `lead`
/// seconds of silence when that is before the start of the reference.
fn addClip(arena: std.mem.Allocator, io: Io, m: *Value, duration: f64) !void {
    const reference_start = envelope.number(m.object.get("reference_start")) orelse 0;
    const query_start = envelope.number(m.object.get("query_start")) orelse 0;
    const offset = reference_start - query_start;
    const lead = @max(0, -offset);
    try m.object.put(arena, "offset", try envelope.fixed(arena, offset));
    try m.object.put(arena, "lead", try envelope.fixed(arena, lead));

    const path = if (m.object.get("path")) |p| (if (p == .string) p.string else "") else "";
    var audio: Value = .null;
    if (path.len > 0 and duration - lead > 0) {
        if (Io.Dir.cwd().access(io, path, .{})) |_| {} else |_| {
            // Stored with an explicit identifier (--with-ids, /api/store):
            // the database records that identifier, not the file.
            try m.object.put(arena, "audio_error", .{ .string = try std.fmt.allocPrint(arena, "no audio file at '{s}': items stored with an explicit identifier only record that identifier, not the file", .{path}) });
            try m.object.put(arena, "audio", .null);
            return;
        }
        if (clip(arena, io, path, @max(0, offset), duration - lead)) |mp3| {
            audio = .{ .string = try base64(arena, mp3) };
        } else |_| {
            try m.object.put(arena, "audio_error", .{ .string = try std.fmt.allocPrint(arena, "could not read the reference audio at {s}", .{path}) });
        }
    }
    try m.object.put(arena, "audio", audio);
}

/// `duration` seconds of `input` from `start` as 44.1 kHz stereo MP3.
fn clip(arena: std.mem.Allocator, io: Io, input: []const u8, start: f64, duration: f64) ![]const u8 {
    const ss = try std.fmt.allocPrint(arena, "{d:.3}", .{start});
    const t = try std.fmt.allocPrint(arena, "{d:.3}", .{duration});
    const r = try std.process.run(arena, io, .{ .argv = &.{
        "ffmpeg", "-hide_banner", "-nostdin",  "-loglevel", "error", "-ss", ss,  "-i", input, "-t", t,
        "-vn",    "-ac",          "2",         "-ar",       "44100", "-c:a", "libmp3lame", "-b:a", "192k", "-f", "mp3",
        "pipe:1",
    } });
    const ok = r.term == .exited and r.term.exited == 0 and r.stdout.len > 0;
    if (!ok) {
        log.warn("ffmpeg could not cut a clip from '{s}': {s}", .{ input, std.mem.trim(u8, r.stderr, " \r\n") });
        return error.FFmpegFailed;
    }
    return r.stdout;
}

fn base64(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const enc = std.base64.standard.Encoder;
    const out = try arena.alloc(u8, enc.calcSize(bytes.len));
    return enc.encode(out, bytes);
}

/// The results page showing only `message` (and the link to a new query).
pub fn errorPage(arena: std.mem.Allocator, status: http.Status, message: []const u8) !Page {
    var data: json.ObjectMap = .empty;
    try data.put(arena, "error", .{ .string = message });
    return .{ .status = status, .html = try render(arena, .{ .object = data }), .summary = message };
}

/// results_html with `data` in place of the placeholder. Every '<' is
/// written as \u003c: in JSON it only occurs inside strings, and so no path
/// can end the script element ("</script>") or open a comment.
pub fn render(arena: std.mem.Allocator, data: Value) ![]const u8 {
    var text: Io.Writer.Allocating = .init(arena);
    try json.Stringify.value(data, .{}, &text.writer);
    const at = std.mem.indexOf(u8, results_html, placeholder).?;
    var out: Io.Writer.Allocating = .init(arena);
    try out.writer.writeAll(results_html[0..at]);
    var remaining = text.written();
    while (std.mem.indexOfScalar(u8, remaining, '<')) |i| {
        try out.writer.writeAll(remaining[0..i]);
        try out.writer.writeAll("\\u003c");
        remaining = remaining[i + 1 ..];
    }
    try out.writer.writeAll(remaining);
    try out.writer.writeAll(results_html[at + placeholder.len ..]);
    return out.written();
}

// ---------------------------------------------------------------------------
// multipart/form-data
// ---------------------------------------------------------------------------

/// The boundary of a multipart/form-data content type, or null.
pub fn boundaryOf(content_type: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, content_type, ';');
    const media = std.mem.trim(u8, it.first(), " \t");
    if (!std.ascii.eqlIgnoreCase(media, "multipart/form-data")) return null;
    while (it.next()) |param| {
        const p = std.mem.trim(u8, param, " \t");
        const eq = std.mem.indexOfScalar(u8, p, '=') orelse continue;
        if (!std.ascii.eqlIgnoreCase(p[0..eq], "boundary")) continue;
        const value = unquote(p[eq + 1 ..]);
        return if (value.len > 0) value else null;
    }
    return null;
}

pub const FilePart = struct {
    /// As sent by the browser (the base name); empty when absent.
    filename: []const u8,
    data: []const u8,
};

/// The part of form field `field` in a multipart body.
pub fn filePart(body: []const u8, boundary: []const u8, field: []const u8) !FilePart {
    var delim_buf: [80]u8 = undefined; // RFC 2046: boundaries are at most 70 characters
    const delim = std.fmt.bufPrint(&delim_buf, "\r\n--{s}", .{boundary}) catch return error.MalformedMultipart;
    // The first delimiter may start the body without the preceding CRLF.
    var pos: usize = if (std.mem.startsWith(u8, body, delim[2..])) delim.len - 2 else (std.mem.indexOf(u8, body, delim) orelse return error.MalformedMultipart) + delim.len;
    while (true) {
        // After a delimiter: "--" ends the body, else CRLF and a part.
        if (std.mem.startsWith(u8, body[pos..], "--")) return error.NoFilePart;
        if (!std.mem.startsWith(u8, body[pos..], "\r\n")) return error.MalformedMultipart;
        const headers_start = pos + 2;
        const headers_end = std.mem.indexOfPos(u8, body, headers_start, "\r\n\r\n") orelse return error.MalformedMultipart;
        const data_start = headers_end + 4;
        const data_end = std.mem.indexOfPos(u8, body, data_start, delim) orelse return error.MalformedMultipart;

        var lines = std.mem.splitSequence(u8, body[headers_start..headers_end], "\r\n");
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), "content-disposition")) continue;
            const disposition = line[colon + 1 ..];
            const name = dispositionParam(disposition, "name") orelse continue;
            if (!std.mem.eql(u8, name, field)) continue;
            return .{ .filename = dispositionParam(disposition, "filename") orelse "", .data = body[data_start..data_end] };
        }
        pos = data_end + delim.len;
    }
}

/// A parameter of a Content-Disposition value: `form-data; name="audio"`.
/// Quoted values may contain ';' (browsers write a filename's '"' as %22).
fn dispositionParam(disposition: []const u8, key: []const u8) ?[]const u8 {
    var i = std.mem.indexOfScalar(u8, disposition, ';') orelse return null;
    while (i < disposition.len) {
        i += 1; // past ';'
        while (i < disposition.len and (disposition[i] == ' ' or disposition[i] == '\t')) i += 1;
        const eq = std.mem.indexOfScalarPos(u8, disposition, i, '=') orelse return null;
        const name = std.mem.trim(u8, disposition[i..eq], " \t");
        var value: []const u8 = undefined;
        if (eq + 1 < disposition.len and disposition[eq + 1] == '"') {
            const close = std.mem.indexOfScalarPos(u8, disposition, eq + 2, '"') orelse return null;
            value = disposition[eq + 2 .. close];
            i = std.mem.indexOfScalarPos(u8, disposition, close, ';') orelse disposition.len;
        } else {
            const end = std.mem.indexOfScalarPos(u8, disposition, eq, ';') orelse disposition.len;
            value = std.mem.trim(u8, disposition[eq + 1 .. end], " \t");
            i = end;
        }
        if (std.ascii.eqlIgnoreCase(name, key)) return value;
    }
    return null;
}

fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return s[1 .. s.len - 1];
    return s;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "boundaryOf reads plain and quoted boundaries" {
    try testing.expectEqualStrings("----abc", boundaryOf("multipart/form-data; boundary=----abc").?);
    try testing.expectEqualStrings("a b", boundaryOf("Multipart/Form-Data;charset=utf-8; Boundary=\"a b\"").?);
    try testing.expect(boundaryOf("application/octet-stream") == null);
    try testing.expect(boundaryOf("multipart/form-data") == null);
    try testing.expect(boundaryOf("multipart/form-data; boundary=") == null);
}

test "filePart finds the named file field" {
    const body = "--XyZ\r\n" ++
        "Content-Disposition: form-data; name=\"note\"\r\n\r\n" ++
        "hello\r\n" ++
        "--XyZ\r\n" ++
        "Content-Disposition: form-data; name=\"audio\"; filename=\"a; b.mp3\"\r\n" ++
        "Content-Type: audio/mpeg\r\n\r\n" ++
        "ID3\r\n\x00binary\r\n" ++
        "--XyZ--\r\n";
    const part = try filePart(body, "XyZ", "audio");
    try testing.expectEqualStrings("ID3\r\n\x00binary", part.data);
    try testing.expectEqualStrings("a; b.mp3", part.filename);
    try testing.expectError(error.NoFilePart, filePart(body, "XyZ", "missing"));
    try testing.expectError(error.MalformedMultipart, filePart(body[0 .. body.len - 12], "XyZ", "audio"));
    try testing.expectError(error.MalformedMultipart, filePart("no boundary here", "XyZ", "audio"));
}

test "render replaces the placeholder and escapes '<'" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const page = try errorPage(arena, .bad_request, "</script><!-- x");
    try testing.expect(std.mem.indexOf(u8, page.html, placeholder) == null);
    try testing.expect(std.mem.indexOf(u8, page.html, "\\u003c/script>\\u003c!-- x") != null);
    try testing.expectEqual(http.Status.bad_request, page.status);
}

test "isUiPath" {
    try testing.expect(isUiPath("/ui"));
    try testing.expect(isUiPath("/ui/"));
    try testing.expect(!isUiPath("/uix"));
    try testing.expect(!isUiPath("/api/ui"));
}
