//! The HTTP server: accepts connections, one concurrent task per connection
//! (keep-alive), routes /api/<endpoint>, checks parameters and the body, and
//! answers every request with a response envelope. What an endpoint does is
//! up to the `Backend`.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const http = std.http;
const log = std.log.scoped(.olaf_rest);

const api = @import("olaf_rest_api.zig");
const params = @import("olaf_rest_params.zig");
const envelope = @import("olaf_rest_envelope.zig");

pub const Options = struct {
    host: []const u8,
    port: u16,
    /// Largest accepted audio upload.
    max_body_bytes: usize,
    /// Shown at startup ("olaf rest serve", "olaf rest serve-lb").
    name: []const u8 = "olaf rest serve",
    /// Query summaries keep at most this many matches per query (the
    /// config's max_results), so combined databases answer like one.
    max_matches: ?usize = null,
    /// Starts every request log line, e.g. "[127.0.0.1:8921] " when one
    /// process serves several instances; empty for one.
    log_label: []const u8 = "",
};

/// Where a server listens: an IP address (v4 or v6, without brackets) and a port.
pub const ListenAddress = struct {
    host: []const u8,
    port: u16,
};

/// Parse a listen address: "host:port" ("0.0.0.0:8920", "[::1]:8920") or
/// only a port ("8920"), which listens on 127.0.0.1. Null when invalid.
pub fn parseListen(text: []const u8) ?ListenAddress {
    const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse
        return .{ .host = "127.0.0.1", .port = parsePort(text) orelse return null };
    var host = text[0..colon];
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') host = host[1 .. host.len - 1];
    const port = parsePort(text[colon + 1 ..]) orelse return null;
    _ = Io.net.IpAddress.parse(host, port) catch return null;
    return .{ .host = host, .port = port };
}

fn parsePort(text: []const u8) ?u16 {
    for (text) |ch| if (!std.ascii.isDigit(ch)) return null;
    const port = std.fmt.parseInt(u16, text, 10) catch return null;
    return if (port == 0) null else port;
}

/// The URL a client on this machine reaches a server listening on `address`
/// at: a wildcard address (0.0.0.0, ::) is reached on the loopback address.
pub fn clientUrl(allocator: std.mem.Allocator, address: ListenAddress) ![]u8 {
    const is_v6 = std.mem.indexOfScalar(u8, address.host, ':') != null;
    const host = if (std.mem.eql(u8, address.host, "0.0.0.0"))
        "127.0.0.1"
    else if (is_v6 and std.mem.eql(u8, address.host, "::"))
        "::1"
    else
        address.host;
    if (is_v6) return std.fmt.allocPrint(allocator, "http://[{s}]:{d}", .{ host, address.port });
    return std.fmt.allocPrint(allocator, "http://{s}:{d}", .{ host, address.port });
}

const json_headers = [_]http.Header{.{ .name = "content-type", .value = "application/json" }};

/// Listen on `opts.host:opts.port` and serve until the process is stopped.
pub fn serve(gpa: std.mem.Allocator, io: Io, backend: api.Backend, opts: Options) !void {
    var listener = try bind(io, opts);
    defer listener.deinit(io);
    run(gpa, io, backend, opts, &listener);
}

/// Serve `backends[i]` with `opts[i]`, all in this process until it is
/// stopped. Every address is bound first: a busy port fails before any
/// instance serves.
pub fn serveAll(gpa: std.mem.Allocator, io: Io, backends: []const api.Backend, opts: []const Options) !void {
    std.debug.assert(backends.len == opts.len);
    const listeners = try gpa.alloc(Io.net.Server, opts.len);
    defer gpa.free(listeners);
    var bound: usize = 0;
    defer for (listeners[0..bound]) |*l| l.deinit(io);
    for (opts, listeners) |o, *l| {
        l.* = try bind(io, o);
        bound += 1;
    }
    var group: Io.Group = .init;
    defer group.cancel(io);
    for (backends, opts, listeners) |b, o, *l| try group.concurrent(io, run, .{ gpa, io, b, o, l });
    try group.await(io);
}

/// Listen on `opts.host:opts.port`, with a clear message when that fails.
pub fn bind(io: Io, opts: Options) !Io.net.Server {
    const address = Io.net.IpAddress.parse(opts.host, opts.port) catch {
        log.err("'{s}' is not an IP address to listen on (e.g. 127.0.0.1 or 0.0.0.0)", .{opts.host});
        return error.InvalidConfigValue;
    };
    const listener = listenExclusive(io, address) catch |err| {
        switch (err) {
            error.AddressInUse => log.err("port {d} on {s} is already in use (is another olaf rest serve running?)", .{ opts.port, opts.host }),
            else => log.err("cannot listen on {s}:{d}: {}", .{ opts.host, opts.port, err }),
        }
        return error.ListenFailed;
    };
    std.debug.print("{s} listening on http://{s}:{d}\n", .{ opts.name, opts.host, opts.port });
    return listener;
}

/// Accept connections on `listener` until canceled.
fn run(gpa: std.mem.Allocator, io: Io, backend: api.Backend, opts: Options, listener: *Io.net.Server) void {
    // Finished connection tasks release their resources; the group only
    // holds the running ones.
    var group: Io.Group = .init;
    defer group.cancel(io);
    while (true) {
        const stream = listener.accept(io) catch |err| switch (err) {
            error.Canceled => return,
            error.ConnectionAborted => continue,
            else => {
                // e.g. out of file descriptors: back off instead of spinning.
                log.warn("accept failed: {}", .{err});
                io.sleep(.fromMilliseconds(100), .awake) catch return;
                continue;
            },
        };
        group.concurrent(io, connection, .{ gpa, io, backend, opts, stream }) catch {
            // No thread available: serve this connection before accepting more.
            connection(gpa, io, backend, opts, stream);
        };
    }
}

/// Listen on `address`, owning the port: a port another socket listens on
/// is error.AddressInUse. std's `reuse_address` also sets SO_REUSEPORT on
/// POSIX, which lets a second server share the port (the kernel then splits
/// connections between them). Here only SO_REUSEADDR is set, which a restart
/// needs while earlier connections are in TIME_WAIT. On Windows SO_REUSEADDR
/// would itself allow taking over a busy port, so it is not set there.
pub fn listenExclusive(io: Io, address: Io.net.IpAddress) !Io.net.Server {
    if (builtin.os.tag == .windows) {
        return address.listen(io, .{ .reuse_address = false });
    }
    const c = std.c;
    const family: c_uint = switch (address) {
        .ip4 => c.AF.INET,
        .ip6 => c.AF.INET6,
    };
    const fd = c.socket(family, c.SOCK.STREAM, 0);
    if (fd < 0) return error.ListenFailed;
    errdefer _ = c.close(fd);
    // Not inherited by the ffmpeg children, which would keep the port.
    if (c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)) < 0) return error.ListenFailed;
    const one: c_int = 1;
    if (c.setsockopt(fd, c.SOL.SOCKET, c.SO.REUSEADDR, &one, @sizeOf(c_int)) < 0) return error.ListenFailed;

    const rc = switch (address) {
        .ip4 => |a| blk: {
            var sa: c.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, a.port), .addr = @bitCast(a.bytes) };
            break :blk c.bind(fd, @ptrCast(&sa), @sizeOf(c.sockaddr.in));
        },
        .ip6 => |a| blk: {
            var sa: c.sockaddr.in6 = .{ .port = std.mem.nativeToBig(u16, a.port), .flowinfo = a.flow, .addr = a.bytes, .scope_id = a.interface.index };
            break :blk c.bind(fd, @ptrCast(&sa), @sizeOf(c.sockaddr.in6));
        },
    };
    if (rc < 0) return switch (c.errno(rc)) {
        .ADDRINUSE => error.AddressInUse,
        .ACCES => error.AccessDenied,
        .ADDRNOTAVAIL => error.AddressUnavailable,
        else => error.ListenFailed,
    };
    if (c.listen(fd, 128) < 0) return switch (c.errno(-1)) {
        .ADDRINUSE => error.AddressInUse,
        else => error.ListenFailed,
    };

    // The port the OS picked when `address` asked for port 0.
    var bound = address;
    var storage: c.sockaddr.storage = undefined;
    var len: c.socklen_t = @sizeOf(c.sockaddr.storage);
    if (c.getsockname(fd, @ptrCast(&storage), &len) == 0) {
        const port: u16 = switch (address) {
            .ip4 => std.mem.bigToNative(u16, @as(*const c.sockaddr.in, @ptrCast(@alignCast(&storage))).port),
            .ip6 => std.mem.bigToNative(u16, @as(*const c.sockaddr.in6, @ptrCast(@alignCast(&storage))).port),
        };
        bound.setPort(port);
    }
    return .{ .socket = .{ .handle = fd, .address = bound }, .options = {} };
}

test "parseListen accepts host:port or a port" {
    const expectEqual = std.testing.expectEqual;
    const expectEqualStrings = std.testing.expectEqualStrings;
    const port_only = parseListen("1234").?;
    try expectEqualStrings("127.0.0.1", port_only.host);
    try expectEqual(@as(u16, 1234), port_only.port);
    const any = parseListen("0.0.0.0:1224").?;
    try expectEqualStrings("0.0.0.0", any.host);
    try expectEqual(@as(u16, 1224), any.port);
    const v6 = parseListen("[::1]:8920").?;
    try expectEqualStrings("::1", v6.host);
    try expectEqual(@as(u16, 8920), v6.port);
    for ([_][]const u8{ "", "0", "70000", "-1", "+80", "host:", ":80", "abc", "localhost:80", "1.2.3:80", "127.0.0.1:0", "127.0.0.1:x" }) |bad| {
        std.testing.expect(parseListen(bad) == null) catch |err| {
            std.debug.print("parseListen accepted '{s}'\n", .{bad});
            return err;
        };
    }
}

test "clientUrl reaches a wildcard address on loopback" {
    const allocator = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "127.0.0.1:8920", "http://127.0.0.1:8920" },
        .{ "0.0.0.0:1224", "http://127.0.0.1:1224" },
        .{ "10.0.0.5:8920", "http://10.0.0.5:8920" },
        .{ "[::]:8920", "http://[::1]:8920" },
        .{ "[::1]:8920", "http://[::1]:8920" },
    };
    for (cases) |case| {
        const url = try clientUrl(allocator, parseListen(case[0]).?);
        defer allocator.free(url);
        try std.testing.expectEqualStrings(case[1], url);
    }
}

/// The log line of a request answered with `results`, each given as the
/// endpoint and its data JSON (null: failed, unreachable).
fn testLogLine(arena: std.mem.Allocator, endpoint: api.Endpoint, identifier: ?[]const u8, body_bytes: usize, results: []const struct { []const u8, ?[]const u8 }) ![]const u8 {
    const list = try arena.alloc(api.Result, results.len);
    for (results, list) |r, *out| {
        out.* = if (r[1]) |data|
            .{ .endpoint = r[0], .status = 200, .data = try std.json.parseFromSliceLeaky(std.json.Value, arena, data, envelope.parse_options) }
        else
            .failure(r[0], 502, "backend unreachable: ConnectionRefused");
    }
    var line: Io.Writer.Allocating = .init(arena);
    try formatRequestLog(&line.writer, .{
        .method = if (endpoint.takesAudio()) "POST" else "GET",
        .path = try std.fmt.allocPrint(arena, "/api/{s}", .{endpoint.path()}),
        .identifier = identifier,
        .body_bytes = body_bytes,
        .status = envelope.status(list),
        .ms = 41,
        .endpoint = endpoint,
        .results = list,
        .summary = try envelope.summary(arena, endpoint, list, .{}),
    });
    return line.written();
}

test "formatRequestLog says what the endpoints answered" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = "http://127.0.0.1:8920";
    const b = "http://127.0.0.1:8921";
    const expectEqualStrings = std.testing.expectEqualStrings;

    try expectEqualStrings(
        "POST /api/store identifier=song 3.0 MB -> 200 in 41 ms: stored on local (internal_id 7)",
        try testLogLine(arena, .store, "song", 3 * 1024 * 1024, &.{.{ "local", "{\"action\":\"store\",\"internal_id\":7}" }}),
    );
    try expectEqualStrings(
        "POST /api/store identifier=song 2 KB -> 200 in 41 ms: 1/2 endpoints ok, skipped (already stored) on http://127.0.0.1:8921 (internal_id 7)",
        try testLogLine(arena, .store, "song", 1500, &.{ .{ a, null }, .{ b, "{\"action\":\"skip\",\"internal_id\":7}" } }),
    );
    try expectEqualStrings(
        "POST /api/query 1 KB -> 200 in 41 ms: 2/2 endpoints ok, 2 matches, best y (match_count 12) on http://127.0.0.1:8921",
        try testLogLine(arena, .query, null, 1024, &.{
            .{ a, "{\"queries\":[{\"query_offset\":0.000,\"matches\":[{\"match_count\":7,\"path\":\"x\"}]}]}" },
            .{ b, "{\"queries\":[{\"query_offset\":0.000,\"matches\":[{\"match_count\":12,\"path\":\"y\"}]}]}" },
        }),
    );
    try expectEqualStrings(
        "POST /api/query 1 KB -> 200 in 41 ms: 0 matches",
        try testLogLine(arena, .query, null, 1024, &.{.{ "local", "{\"queries\":[{\"query_offset\":0.000,\"matches\":[]}]}" }}),
    );
    try expectEqualStrings(
        "GET /api/stats -> 200 in 41 ms: 2/2 endpoints ok, 3 songs",
        try testLogLine(arena, .stats, null, 0, &.{ .{ a, "{\"song_count\":1}" }, .{ b, "{\"song_count\":2}" } }),
    );
    try expectEqualStrings(
        "GET /api/healthz -> 200 in 41 ms: 1/2 endpoints ok",
        try testLogLine(arena, .health, null, 0, &.{ .{ a, "{\"status\":\"ok\"}" }, .{ b, null } }),
    );
    try expectEqualStrings(
        "GET /api/healthz -> 200 in 41 ms: ok",
        try testLogLine(arena, .health, null, 0, &.{.{ "local", "{\"status\":\"ok\"}" }}),
    );
    try expectEqualStrings(
        "GET /api/healthz -> 502 in 41 ms: failed",
        try testLogLine(arena, .health, null, 0, &.{.{ a, null }}),
    );
}

test "listenExclusive owns its port" {
    const io = std.testing.io;
    const any = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var first = try listenExclusive(io, any);
    const port = first.socket.address.getPort();
    try std.testing.expect(port != 0);

    const same = try Io.net.IpAddress.parse("127.0.0.1", port);
    try std.testing.expectError(error.AddressInUse, listenExclusive(io, same));
    // std's listen with reuse_address could share the port; ours refuses too.
    try std.testing.expectError(error.AddressInUse, same.listen(io, .{ .reuse_address = true }));

    first.deinit(io);
    var again = try listenExclusive(io, same);
    again.deinit(io);
}

fn connection(gpa: std.mem.Allocator, io: Io, backend: api.Backend, opts: Options, stream: Io.net.Stream) void {
    defer stream.close(io);
    var recv_buf: [16 * 1024]u8 = undefined;
    var send_buf: [16 * 1024]u8 = undefined;
    var reader = stream.reader(io, &recv_buf);
    var writer = stream.writer(io, &send_buf);
    var server = http.Server.init(&reader.interface, &writer.interface);
    while (true) {
        var request = server.receiveHead() catch return; // closed, or not HTTP
        const keep_alive = handle(gpa, io, backend, opts, &request) catch |err| {
            log.warn("request failed: {}", .{err});
            return;
        };
        if (!keep_alive) return;
    }
}

/// Answer one request; returns whether the connection can be reused.
fn handle(gpa: std.mem.Allocator, io: Io, backend: api.Backend, opts: Options, request: *http.Server.Request) !bool {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const start = Io.Clock.awake.now(io);

    // The head's strings are invalidated once the body is read.
    const method = request.head.method;
    const target = try arena.dupe(u8, request.head.target);
    const q = std.mem.indexOfScalar(u8, target, '?');
    const path = target[0 .. q orelse target.len];
    const raw_query = if (q) |i| target[i + 1 ..] else "";

    const endpoint = api.Endpoint.route(path) orelse
        return reject(request, arena, opts, .not_found, "unknown path; use /api/store, /api/query, /api/stats or /api/healthz");
    const wanted: http.Method = if (endpoint.takesAudio()) .POST else .GET;
    if (method != wanted and !(wanted == .GET and method == .HEAD)) {
        return reject(request, arena, opts, .method_not_allowed, try std.fmt.allocPrint(arena, "/api/{s} expects {s}", .{ endpoint.path(), @tagName(wanted) }));
    }
    var message: []const u8 = "";
    const p = params.parse(arena, endpoint, raw_query, &message) catch |err| switch (err) {
        error.InvalidParameter => return reject(request, arena, opts, .bad_request, message),
        else => |e| return e,
    };

    var body: []const u8 = "";
    if (endpoint.takesAudio()) {
        const too_large = try std.fmt.allocPrint(arena, "audio larger than rest_max_body_mb ({d} bytes)", .{opts.max_body_bytes});
        if (request.head.content_length) |len| if (len > opts.max_body_bytes) {
            return reject(request, arena, opts, .payload_too_large, too_large);
        };
        var transfer_buf: [8192]u8 = undefined;
        const r = request.readerExpectContinue(&transfer_buf) catch return false;
        body = r.allocRemaining(arena, .limited(opts.max_body_bytes)) catch |err| switch (err) {
            // Chunked upload over the limit: the rest is not read.
            error.StreamTooLong => return respond(request, arena, opts, .payload_too_large, false, .{ .message = too_large }),
            else => return false,
        };
        if (body.len == 0) return respond(request, arena, opts, .bad_request, true, .{ .message = "empty body: send the audio file as the request body" });
    }

    const results = backend.handle(arena, io, .{ .endpoint = endpoint, .params = p, .raw_query = raw_query, .body = body }) catch |err| blk: {
        const one = try arena.alloc(api.Result, 1);
        one[0] = .failure("local", 500, @errorName(err));
        break :blk one;
    };
    const status: http.Status = @enumFromInt(@as(u10, @intCast(@min(envelope.status(results), 999))));
    const keep = try respond(request, arena, opts, status, true, .{ .results = .{ endpoint, results } });

    const ms = start.durationTo(Io.Clock.awake.now(io)).toMilliseconds();
    var line: Io.Writer.Allocating = .init(arena);
    try formatRequestLog(&line.writer, .{
        .label = opts.log_label,
        .method = @tagName(method),
        .path = path,
        .identifier = p.identifier,
        .body_bytes = body.len,
        .status = @intFromEnum(status),
        .ms = ms,
        .endpoint = endpoint,
        .results = results,
        .summary = try envelope.summary(arena, endpoint, results, .{ .max_matches = opts.max_matches }),
    });
    log.info("{s}", .{line.written()});
    for (results) |r| if (r.err) |e| log.warn("{s}{s}: {d} {s}", .{ opts.log_label, r.endpoint, r.status, e });
    return keep;
}

/// What one answered request is logged with.
pub const RequestLog = struct {
    label: []const u8 = "",
    method: []const u8,
    path: []const u8,
    identifier: ?[]const u8 = null,
    body_bytes: usize = 0,
    status: u16,
    ms: i64,
    endpoint: api.Endpoint,
    results: []const api.Result,
    /// The response's summary (`envelope.summary`).
    summary: std.json.Value,
};

/// One line per request: what was asked and what the endpoints answered,
/// e.g. "POST /api/store identifier=song 3.1 MB -> 200 in 41 ms: stored on
/// http://127.0.0.1:8921 (internal_id 7)".
pub fn formatRequestLog(w: *Io.Writer, e: RequestLog) !void {
    try w.print("{s}{s} {s}", .{ e.label, e.method, e.path });
    if (e.identifier) |id| try w.print(" identifier={s}", .{id});
    if (e.body_bytes >= 1024 * 1024) {
        try w.print(" {d:.1} MB", .{@as(f64, @floatFromInt(e.body_bytes)) / (1024 * 1024)});
    } else if (e.body_bytes > 0) {
        try w.print(" {d} KB", .{(e.body_bytes + 1023) / 1024});
    }
    try w.print(" -> {d} in {d} ms", .{ e.status, e.ms });

    var n_ok: usize = 0;
    for (e.results) |r| n_ok += @intFromBool(r.ok());
    if (n_ok == 0) return w.writeAll(": failed");
    try w.writeAll(": ");
    // Counts only when there is more than one endpoint, or a failure.
    const counts = e.results.len > 1 or n_ok < e.results.len;
    if (counts) try w.print("{d}/{d} endpoints ok", .{ n_ok, e.results.len });

    const s = e.summary;
    switch (e.endpoint) {
        .store => {
            if (counts) try w.writeAll(", ");
            const action = stringField(s, "action") orelse "stored";
            try w.print("{s} on {s}", .{ if (std.mem.eql(u8, action, "skip")) "skipped (already stored)" else "stored", stringField(s, "endpoint") orelse "?" });
            if (fieldOf(s, "internal_id")) |v| if (envelope.number(v)) |id| try w.print(" (internal_id {d})", .{@as(u64, @intFromFloat(id))});
        },
        .query => {
            if (counts) try w.writeAll(", ");
            const matches = fieldOf(s, "matches");
            const n: usize = if (matches) |m| (if (m == .array) m.array.items.len else 0) else 0;
            try w.print("{d} match{s}", .{ n, if (n == 1) "" else "es" });
            if (n > 0) {
                const best = matches.?.array.items[0];
                try w.print(", best {s} (match_count {d})", .{ stringField(best, "path") orelse "?", @as(u64, @intFromFloat(envelope.number(fieldOf(best, "match_count")) orelse 0)) });
                if (e.results.len > 1) try w.print(" on {s}", .{stringField(best, "endpoint") orelse "?"});
            }
        },
        .stats => {
            if (counts) try w.writeAll(", ");
            try w.print("{d} songs", .{@as(u64, @intFromFloat(envelope.number(fieldOf(s, "song_count")) orelse 0))});
        },
        .health => if (!counts) try w.writeAll(stringField(s, "status") orelse "ok"),
    }
}

fn fieldOf(v: std.json.Value, name: []const u8) ?std.json.Value {
    return if (v == .object) v.object.get(name) else null;
}

fn stringField(v: std.json.Value, name: []const u8) ?[]const u8 {
    const f = fieldOf(v, name) orelse return null;
    return if (f == .string) f.string else null;
}

const Content = union(enum) {
    message: []const u8,
    results: struct { api.Endpoint, []const api.Result },
};

fn respond(request: *http.Server.Request, arena: std.mem.Allocator, opts: Options, status: http.Status, keep_alive: bool, content: Content) !bool {
    var out: Io.Writer.Allocating = .init(arena);
    switch (content) {
        .message => |m| try envelope.writeError(&out.writer, m),
        .results => |r| try envelope.write(&out.writer, arena, r[0], r[1], .{ .max_matches = opts.max_matches }),
    }
    try request.respond(out.written(), .{ .status = status, .keep_alive = keep_alive, .extra_headers = &json_headers });
    return keep_alive and request.head.keep_alive;
}

/// Refuse a request before reading its body. A client waiting for
/// "100 Continue" gets the answer instead (and the connection is closed); an
/// announced body up to the size limit is drained first so the client does
/// not see a reset mid-upload; any other body closes the connection.
fn reject(request: *http.Server.Request, arena: std.mem.Allocator, opts: Options, status: http.Status, message: []const u8) !bool {
    log.info("{s}{s} {s} -> {d}: {s}", .{ opts.log_label, @tagName(request.head.method), request.head.target, @intFromEnum(status), message });
    var keep_alive = true;
    if (request.head.expect != null) {
        request.head.expect = null;
        keep_alive = false;
    } else if (request.head.method.requestHasBody()) {
        const len = request.head.content_length orelse std.math.maxInt(u64); // chunked: unknown
        keep_alive = len <= opts.max_body_bytes;
        // Drained here, not by respond(): it skips that for "connection: close".
        if (keep_alive) {
            var transfer_buf: [8192]u8 = undefined;
            _ = request.readerExpectNone(&transfer_buf).discardRemaining() catch return false;
        }
    }
    return respond(request, arena, opts, status, keep_alive, .{ .message = message });
}
