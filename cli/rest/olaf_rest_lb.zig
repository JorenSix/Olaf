//! The load balancer backend (`olaf rest serve-lb`): the same API, answered by
//! other `olaf rest serve` (or `olaf rest serve-lb`) instances. A store goes to one
//! backend (random, or chosen by a hash of the identifier); query, stats and
//! health go to all of them concurrently. Their results are concatenated,
//! "local" renamed to the backend's URL, so the envelope lists every database.
const std = @import("std");
const Io = std.Io;
const http = std.http;
const log = std.log.scoped(.olaf_rest_lb);

const api = @import("olaf_rest_api.zig");
const envelope = @import("olaf_rest_envelope.zig");

/// How `store` picks its backend.
pub const StoreStrategy = enum {
    /// Any backend, uniformly at random.
    random,
    /// Always the same backend for the same identifier, so re-storing is
    /// skipped (skip_duplicates) instead of indexing the audio twice.
    hash,
};

pub const LbBackend = struct {
    /// Base URLs ("http://host:port"), without a trailing slash.
    backends: []const []const u8,
    strategy: StoreStrategy,
    prng: std.Random.DefaultPrng,
    prng_mutex: Io.Mutex = .init,

    /// `backends` must outlive the LbBackend; see `normalizeUrl`.
    pub fn init(io: Io, backends: []const []const u8, strategy: StoreStrategy) LbBackend {
        var seed: [8]u8 = undefined;
        io.random(&seed);
        return .{ .backends = backends, .strategy = strategy, .prng = .init(std.mem.readInt(u64, &seed, .little)) };
    }

    pub fn backend(self: *LbBackend) api.Backend {
        return .{ .ctx = self, .handleFn = handle };
    }

    fn handle(ctx: *anyopaque, arena: std.mem.Allocator, io: Io, req: api.Request) anyerror![]api.Result {
        const self: *LbBackend = @ptrCast(@alignCast(ctx));
        if (self.backends.len == 0) {
            return one(arena, .failure("serve-lb", 503, "no backends configured (rest_lb_backends)"));
        }
        return if (req.endpoint == .store) self.store(arena, io, req) else self.fanOut(arena, io, req);
    }

    fn storeStart(self: *LbBackend, io: Io, identifier: []const u8) usize {
        const n = self.backends.len;
        return switch (self.strategy) {
            .hash => @intCast(std.hash.Wyhash.hash(0, identifier) % n),
            .random => blk: {
                self.prng_mutex.lockUncancelable(io);
                defer self.prng_mutex.unlock(io);
                break :blk self.prng.random().uintLessThan(usize, n);
            },
        };
    }

    /// Store on one backend; when it cannot be reached, the next one.
    fn store(self: *LbBackend, arena: std.mem.Allocator, io: Io, req: api.Request) ![]api.Result {
        const start = self.storeStart(io, req.params.identifier orelse "");
        var last: []api.Result = &.{};
        for (0..self.backends.len) |k| {
            const base = self.backends[(start + k) % self.backends.len];
            const f = try forward(arena, io, base, req);
            if (!f.unreachable_backend) return f.results;
            log.warn("store: {s} unreachable, trying the next backend", .{base});
            last = f.results;
        }
        return last;
    }

    /// Ask every backend at once and concatenate their results.
    fn fanOut(self: *LbBackend, arena: std.mem.Allocator, io: Io, req: api.Request) ![]api.Result {
        const slots = try arena.alloc(Forwarded, self.backends.len);
        const Task = struct {
            fn run(a: std.mem.Allocator, t_io: Io, base: []const u8, r: api.Request, slot: *Forwarded) void {
                slot.* = forward(a, t_io, base, r) catch |err| .{
                    .results = &.{},
                    .unreachable_backend = true,
                    .oom = err,
                };
            }
        };
        var group: Io.Group = .init;
        for (self.backends, slots) |base, *slot| {
            group.concurrent(io, Task.run, .{ arena, io, base, req, slot }) catch Task.run(arena, io, base, req, slot);
        }
        group.await(io) catch {};

        var all: std.ArrayList(api.Result) = .empty;
        for (slots) |slot| {
            if (slot.oom) |e| return e;
            try all.appendSlice(arena, slot.results);
        }
        return all.items;
    }
};

const Forwarded = struct {
    results: []api.Result,
    /// The backend could not be reached (connection refused, reset, ...).
    unreachable_backend: bool = false,
    summary: ?std.json.Value = null,
    oom: ?anyerror = null,
};

/// Send `req` to the instance at `base` ("http://host:port") and return its
/// results, "local" renamed to `base`. Failures (unreachable, not an olaf
/// rest response, a rejected request) are a failed result, not an error.
/// Used by `olaf rest store` / `olaf rest query`.
pub fn send(arena: std.mem.Allocator, io: Io, base: []const u8, req: api.Request) error{OutOfMemory}!Sent {
    const f = try forward(arena, io, base, req);
    return .{ .results = f.results, .summary = f.summary };
}

pub const Sent = struct {
    results: []api.Result,
    /// The instance's summary over its results (null when it failed).
    summary: ?std.json.Value,
};

/// Send `req` to `base` and read back its envelope's results.
fn forward(arena: std.mem.Allocator, io: Io, base: []const u8, req: api.Request) error{OutOfMemory}!Forwarded {
    const url = try std.fmt.allocPrint(arena, "{s}/api/{s}{s}{s}", .{ base, req.endpoint.path(), if (req.raw_query.len > 0) "?" else "", req.raw_query });
    // One client per request: the arena (thread-safe) holds its connection.
    var client: http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();
    var body: Io.Writer.Allocating = .init(arena);

    const res = client.fetch(.{
        .location = .{ .url = url },
        .method = if (req.endpoint.takesAudio()) .POST else .GET,
        .payload = if (req.endpoint.takesAudio()) req.body else null,
        .response_writer = &body.writer,
        .keep_alive = false,
        .headers = .{ .content_type = if (req.endpoint.takesAudio()) .{ .override = "application/octet-stream" } else .default },
    }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .results = try one(arena, .failure(base, 502, try std.fmt.allocPrint(arena, "backend unreachable: {s}", .{@errorName(err)}))), .unreachable_backend = true };
    };
    const status: u16 = @intFromEnum(res.status);

    var message: ?[]const u8 = null;
    var summary: ?std.json.Value = null;
    const results = envelope.parse(arena, body.written(), &message, &summary) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .results = try one(arena, .failure(base, if (status < 400) 502 else status, "not an olaf rest serve response")) };
    };
    if (results.len == 0) return .{ .results = try one(arena, .failure(base, if (status < 400) 502 else status, message orelse "no results")) };
    for (results) |*r| {
        if (std.mem.eql(u8, r.endpoint, "local")) r.endpoint = base;
    }
    return .{ .results = results, .summary = summary };
}

fn one(arena: std.mem.Allocator, r: api.Result) ![]api.Result {
    const list = try arena.alloc(api.Result, 1);
    list[0] = r;
    return list;
}

/// A backend URL as configured, checked and without trailing slashes.
pub fn normalizeUrl(url: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) return null;
    const trimmed = std.mem.trimEnd(u8, url, "/");
    _ = std.Uri.parse(trimmed) catch return null;
    return trimmed;
}

test "normalizeUrl" {
    try std.testing.expectEqualStrings("http://127.0.0.1:8920", normalizeUrl("http://127.0.0.1:8920/").?);
    try std.testing.expectEqualStrings("https://olaf.example.org/node1", normalizeUrl("https://olaf.example.org/node1").?);
    try std.testing.expectEqual(@as(?[]const u8, null), normalizeUrl("127.0.0.1:8920"));
}

test "hash strategy keeps an identifier on one backend" {
    var lb = LbBackend.init(std.testing.io, &.{ "http://a", "http://b", "http://c" }, .hash);
    const first = lb.storeStart(std.testing.io, "song-42");
    for (0..10) |_| try std.testing.expectEqual(first, lb.storeStart(std.testing.io, "song-42"));
    lb.strategy = .random;
    for (0..10) |_| try std.testing.expect(lb.storeStart(std.testing.io, "x") < 3);
}
