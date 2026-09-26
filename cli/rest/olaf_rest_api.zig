//! The types shared by the REST server, the response envelope and the load
//! balancer: the endpoints, a parsed request, one endpoint's result and the
//! `Backend` interface that answers requests (a local database in the CLI,
//! or `LbBackend`, which forwards to other `olaf rest serve` instances).
const std = @import("std");
const Io = std.Io;

const Params = @import("olaf_rest_params.zig").Params;

pub const Endpoint = enum {
    store,
    query,
    stats,
    health,

    /// The path below /api/ ("healthz"; "healtz" is accepted too, see route).
    pub fn path(e: Endpoint) []const u8 {
        return switch (e) {
            .store => "store",
            .query => "query",
            .stats => "stats",
            .health => "healthz",
        };
    }

    /// store and query take audio as the POST body; stats and health are GETs.
    pub fn takesAudio(e: Endpoint) bool {
        return e == .store or e == .query;
    }

    /// The endpoint for a request path, or null. Trailing slashes are ignored.
    pub fn route(target_path: []const u8) ?Endpoint {
        const p = std.mem.trimEnd(u8, target_path, "/");
        const prefix = "/api/";
        if (!std.mem.startsWith(u8, p, prefix)) return null;
        const name = p[prefix.len..];
        if (std.mem.eql(u8, name, "healtz")) return .health;
        inline for (std.meta.fields(Endpoint)) |f| {
            const e: Endpoint = @enumFromInt(f.value);
            if (std.mem.eql(u8, name, e.path())) return e;
        }
        return null;
    }
};

pub const Request = struct {
    endpoint: Endpoint,
    params: Params,
    /// The query string (without '?'), forwarded unchanged by the load balancer.
    raw_query: []const u8,
    /// The uploaded audio (store / query); empty otherwise.
    body: []const u8,
};

/// What one endpoint (one database) answered.
pub const Result = struct {
    /// "local" for the database of the instance itself, else the backend URL.
    endpoint: []const u8,
    /// HTTP status of this endpoint's answer.
    status: u16,
    /// The endpoint's answer; null when it failed.
    data: ?std.json.Value = null,
    /// Why it failed; null on success.
    err: ?[]const u8 = null,

    pub fn ok(r: Result) bool {
        return r.err == null;
    }

    pub fn failure(endpoint: []const u8, status: u16, message: []const u8) Result {
        return .{ .endpoint = endpoint, .status = status, .err = message };
    }
};

/// Answers requests with one result per endpoint that served them. Called
/// concurrently from connection tasks; all memory comes from `arena`, which
/// lives until the response is sent.
pub const Backend = struct {
    ctx: *anyopaque,
    handleFn: *const fn (ctx: *anyopaque, arena: std.mem.Allocator, io: Io, req: Request) anyerror![]Result,

    pub fn handle(b: Backend, arena: std.mem.Allocator, io: Io, req: Request) anyerror![]Result {
        return b.handleFn(b.ctx, arena, io, req);
    }
};

test "route" {
    try std.testing.expectEqual(Endpoint.store, Endpoint.route("/api/store").?);
    try std.testing.expectEqual(Endpoint.query, Endpoint.route("/api/query/").?);
    try std.testing.expectEqual(Endpoint.health, Endpoint.route("/api/healthz").?);
    try std.testing.expectEqual(Endpoint.health, Endpoint.route("/api/healtz").?);
    try std.testing.expectEqual(Endpoint.stats, Endpoint.route("/api/stats").?);
    try std.testing.expectEqual(@as(?Endpoint, null), Endpoint.route("/api/delete"));
    try std.testing.expectEqual(@as(?Endpoint, null), Endpoint.route("/store"));
}
