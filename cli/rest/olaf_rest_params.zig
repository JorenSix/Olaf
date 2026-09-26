//! Request parameters: the URL query string, named like the CLI options
//! (`identifier` is the audio identifier of `olaf store --with-ids`).
const std = @import("std");

const Endpoint = @import("olaf_rest_api.zig").Endpoint;

pub const Params = struct {
    /// store: the audio identifier (required). query: the label reported as
    /// query_path, and the identity excluded by no_identity_match.
    identifier: ?[]const u8 = null,
    /// store: re-store an identifier that is already indexed (`olaf store -f`).
    force: bool = false,
    /// query: drop matches against `identifier` (`--no-identity-match`).
    no_identity_match: bool = false,
    /// query: match fragments of fragment_duration_in_seconds (`--fragmented`).
    fragmented: bool = false,
};

pub const ParseError = error{ InvalidParameter, OutOfMemory };

/// Which parameters each endpoint accepts; anything else is an error, like an
/// unknown CLI option.
fn allowed(endpoint: Endpoint, name: []const u8) bool {
    const names: []const []const u8 = switch (endpoint) {
        .store => &.{ "identifier", "force" },
        .query => &.{ "identifier", "no_identity_match", "fragmented" },
        .stats, .health => &.{},
    };
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// Parse `query` ("a=1&b=x"); on error `message` explains it (arena-owned).
pub fn parse(arena: std.mem.Allocator, endpoint: Endpoint, query: []const u8, message: *[]const u8) ParseError!Params {
    var p = Params{};
    var it = std.mem.tokenizeScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=');
        const name = try decode(arena, pair[0 .. eq orelse pair.len]);
        const value = try decode(arena, if (eq) |i| pair[i + 1 ..] else "");
        if (!allowed(endpoint, name)) {
            message.* = try std.fmt.allocPrint(arena, "unknown parameter '{s}' for /api/{s}", .{ name, endpoint.path() });
            return error.InvalidParameter;
        }
        if (std.mem.eql(u8, name, "identifier")) {
            p.identifier = value;
            continue;
        }
        const flag = parseBool(value) orelse {
            message.* = try std.fmt.allocPrint(arena, "parameter '{s}' expects true or false, got '{s}'", .{ name, value });
            return error.InvalidParameter;
        };
        if (std.mem.eql(u8, name, "force")) p.force = flag;
        if (std.mem.eql(u8, name, "no_identity_match")) p.no_identity_match = flag;
        if (std.mem.eql(u8, name, "fragmented")) p.fragmented = flag;
    }
    if (endpoint == .store and (p.identifier == null or p.identifier.?.len == 0)) {
        message.* = "/api/store needs an 'identifier' parameter";
        return error.InvalidParameter;
    }
    return p;
}

/// The query string for `p` (without '?'): the inverse of `parse`. Only
/// set values are written, and only the endpoint's own parameters.
pub fn encodeQuery(w: *std.Io.Writer, endpoint: Endpoint, p: Params) !void {
    var first = true;
    if (p.identifier) |id| if (allowed(endpoint, "identifier")) {
        try w.writeAll("identifier=");
        try encode(w, id);
        first = false;
    };
    inline for (.{ "force", "no_identity_match", "fragmented" }) |name| {
        if (@field(p, name) and allowed(endpoint, name)) {
            if (!first) try w.writeByte('&');
            try w.writeAll(name ++ "=true");
            first = false;
        }
    }
}

/// A flag given without a value (`?force`) is true.
fn parseBool(v: []const u8) ?bool {
    inline for (.{ "", "1", "true", "yes" }) |t| if (std.ascii.eqlIgnoreCase(v, t)) return true;
    inline for (.{ "0", "false", "no" }) |f| if (std.ascii.eqlIgnoreCase(v, f)) return false;
    return null;
}

/// Percent-decoding, with '+' as a space (form encoding). A malformed escape
/// is kept literally.
pub fn decode(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfAny(u8, s, "%+") == null) return s;
    var out = try arena.alloc(u8, s.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '+') {
            out[n] = ' ';
        } else if (s[i] == '%' and i + 2 < s.len and std.ascii.isHex(s[i + 1]) and std.ascii.isHex(s[i + 2])) {
            out[n] = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch unreachable;
            i += 2;
        } else {
            out[n] = s[i];
        }
        n += 1;
    }
    return out[0..n];
}

/// Percent-encode `s` for a query string value (for clients and tests).
pub fn encode(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |ch| {
        if (std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "-._~", ch) != null) {
            try w.writeByte(ch);
        } else {
            try w.print("%{X:0>2}", .{ch});
        }
    }
}

test "parse store and query parameters" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var msg: []const u8 = "";

    const s = try parse(arena, .store, "identifier=my%20song+1&force", &msg);
    try std.testing.expectEqualStrings("my song 1", s.identifier.?);
    try std.testing.expect(s.force);

    const q = try parse(arena, .query, "no_identity_match=true&fragmented=0&identifier=q", &msg);
    try std.testing.expect(q.no_identity_match and !q.fragmented);

    try std.testing.expectError(error.InvalidParameter, parse(arena, .store, "force=1", &msg));
    try std.testing.expectError(error.InvalidParameter, parse(arena, .query, "force=1", &msg));
    try std.testing.expectError(error.InvalidParameter, parse(arena, .query, "fragmented=maybe", &msg));
    try std.testing.expectError(error.InvalidParameter, parse(arena, .stats, "x", &msg));
    _ = try parse(arena, .stats, "", &msg);
}

test "encodeQuery is the inverse of parse" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var msg: []const u8 = "";

    const q = Params{ .identifier = "/music/a b&c=é.mp3", .no_identity_match = true, .fragmented = true };
    var out: std.Io.Writer.Allocating = .init(arena);
    try encodeQuery(&out.writer, .query, q);
    const back = try parse(arena, .query, out.written(), &msg);
    try std.testing.expectEqualStrings(q.identifier.?, back.identifier.?);
    try std.testing.expect(back.no_identity_match and back.fragmented and !back.force);

    // Parameters of other endpoints are left out (force is store-only).
    out.clearRetainingCapacity();
    try encodeQuery(&out.writer, .query, .{ .force = true });
    try std.testing.expectEqualStrings("", out.written());
    out.clearRetainingCapacity();
    try encodeQuery(&out.writer, .store, .{ .identifier = "x", .force = true });
    try std.testing.expect((try parse(arena, .store, out.written(), &msg)).force);
}

test "decode and encode round trip" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("a%zz%", try decode(arena, "a%zz%"));
    try std.testing.expectEqualStrings("é/&=", try decode(arena, "%C3%A9%2F%26%3D"));

    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try encode(&w, "a b/é&");
    try std.testing.expectEqualStrings("a b/é&", try decode(arena, w.buffered()));
}
