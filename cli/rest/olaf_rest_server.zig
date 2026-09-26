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
};

const json_headers = [_]http.Header{.{ .name = "content-type", .value = "application/json" }};

/// Listen on `opts.host:opts.port` and serve until the process is stopped.
pub fn serve(gpa: std.mem.Allocator, io: Io, backend: api.Backend, opts: Options) !void {
    const address = Io.net.IpAddress.parse(opts.host, opts.port) catch {
        log.err("'{s}' is not an IP address to listen on (e.g. 127.0.0.1 or 0.0.0.0)", .{opts.host});
        return error.InvalidConfigValue;
    };
    var listener = listenExclusive(io, address) catch |err| {
        switch (err) {
            error.AddressInUse => log.err("port {d} on {s} is already in use (is another olaf rest serve running?)", .{ opts.port, opts.host }),
            else => log.err("cannot listen on {s}:{d}: {}", .{ opts.host, opts.port, err }),
        }
        return error.ListenFailed;
    };
    defer listener.deinit(io);
    std.debug.print("{s} listening on http://{s}:{d}\n", .{ opts.name, opts.host, opts.port });

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
    log.info("{s} {s} {d} ({d} ms)", .{ @tagName(method), path, @intFromEnum(status), ms });
    return keep;
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
    log.info("{s} {s}: {d} {s}", .{ @tagName(request.head.method), request.head.target, @intFromEnum(status), message });
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
