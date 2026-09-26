//! The REST API's local backend: answers /api/store, /api/query, /api/stats
//! and /api/healthz from this instance's database, with the same session
//! operations and JSON records as `olaf store` / `olaf query --format json`.
//! The HTTP side lives in cli/rest/ (module "olaf_rest") and knows nothing of
//! the core; this file is the only link between the two.
const std = @import("std");
const Io = std.Io;
const json = std.json;
const rest = @import("olaf_rest");

const olaf_cli_config = @import("olaf_cli_config.zig");
const olaf_cli_core = @import("olaf_cli_core.zig");
const olaf_cli_output = @import("olaf_cli_output.zig");
const olaf_cli_session = @import("olaf_cli_session.zig");
const olaf_cli_threading = @import("olaf_cli_threading.zig");
const olaf_cli_util_audio = @import("olaf_cli_util_audio.zig");

const Config = olaf_cli_config.Config;

/// The endpoint name of this instance's own database in responses.
const endpoint_name = "local";

pub const LocalBackend = struct {
    config: *const Config,
    /// Bounds the store / query requests decoding and fingerprinting at once.
    workers: Io.Semaphore,

    pub fn init(config: *const Config) LocalBackend {
        return .{ .config = config, .workers = .{ .permits = config.rest_workers } };
    }

    pub fn backend(self: *LocalBackend) rest.Backend {
        return .{ .ctx = self, .handleFn = handle };
    }

    fn handle(ctx: *anyopaque, arena: std.mem.Allocator, io: Io, req: rest.Request) anyerror![]rest.Result {
        const self: *LocalBackend = @ptrCast(@alignCast(ctx));
        const results = try arena.alloc(rest.Result, 1);
        results[0] = self.answer(arena, io, req) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.FFmpegFailed, error.AudioOpenFailed => .failure(endpoint_name, 422, "could not decode the audio (ffmpeg failed)"),
            error.FileNotFound => .failure(endpoint_name, 500, "ffmpeg or ffprobe not found"),
            else => .failure(endpoint_name, 500, @errorName(err)),
        };
        return results;
    }

    fn answer(self: *LocalBackend, arena: std.mem.Allocator, io: Io, req: rest.Request) !rest.Result {
        const data: json.Value = switch (req.endpoint) {
            .health => blk: {
                var o: json.ObjectMap = .empty;
                try o.put(arena, "status", .{ .string = "ok" });
                break :blk .{ .object = o };
            },
            .stats => try self.stats(arena),
            .store, .query => blk: {
                self.workers.waitUncancelable(io);
                defer self.workers.post(io);
                break :blk if (req.endpoint == .store) try self.store(arena, io, req) else try self.query(arena, io, req);
            },
        };
        return .{ .endpoint = endpoint_name, .status = 200, .data = data };
    }

    fn stats(self: *LocalBackend, arena: std.mem.Allocator) !json.Value {
        const s = try olaf_cli_session.stats(arena, self.config);
        const duration: f64 = s.total_duration;
        const fingerprints: f64 = @floatFromInt(s.total_fingerprints);
        var o: json.ObjectMap = .empty;
        try o.put(arena, "song_count", .{ .integer = s.song_count });
        try o.put(arena, "total_duration_seconds", try rest.envelope.fixed(arena, duration));
        try o.put(arena, "total_fingerprints", .{ .integer = s.total_fingerprints });
        try o.put(arena, "avg_fingerprints_per_second", try rest.envelope.fixed(arena, if (duration > 0) fingerprints / duration else 0));
        return .{ .object = o };
    }

    /// Like `olaf store --with-ids <upload> <identifier>`: the JSON store
    /// (or skip) record.
    fn store(self: *LocalBackend, arena: std.mem.Allocator, io: Io, req: rest.Request) !json.Value {
        const identifier = req.params.identifier.?; // required, checked by the server
        var record: Io.Writer.Allocating = .init(arena);
        const internal_id = olaf_cli_core.nameToId(identifier);

        const stored = (try olaf_cli_session.storedFlags(arena, self.config, &.{identifier}))[0];
        if (stored and self.config.skip_duplicates and !req.params.force) {
            try olaf_cli_output.formatStoreSkip(&record.writer, .json, 0, 1, identifier, internal_id);
        } else {
            const upload = try Upload.create(io, arena, req.body);
            defer upload.deinit();
            const raw = try olaf_cli_threading.TempRaw.create(io, arena, upload.path, self.config, null);
            defer raw.deinit();
            const r = try olaf_cli_session.store(arena, raw.path, identifier, self.config);
            try olaf_cli_output.formatStoreSummary(&record.writer, .json, .{
                .index = 0,
                .total = 1,
                .audio_identifier = identifier,
                .internal_id = r.internal_id,
                .fingerprints = r.stats.fingerprints,
                .audio_seconds = r.stats.audio_seconds,
                .cpu_seconds = r.stats.cpu_seconds,
            });
            var data = try json.parseFromSliceLeaky(json.Value, arena, record.written(), rest.envelope.parse_options);
            // The record rounds audio_seconds to 0.1 s; `olaf rest store`
            // derives fp/s from this one, so it rounds like `olaf store`.
            try data.object.put(arena, "audio_seconds_exact", .{ .number_string = try std.fmt.allocPrint(arena, "{d:.6}", .{r.stats.audio_seconds}) });
            return data;
        }
        return json.parseFromSliceLeaky(json.Value, arena, record.written(), rest.envelope.parse_options);
    }

    /// Like `olaf query --format json [--fragmented]`: {"queries": [...]},
    /// one query object per fragment (one when not fragmented).
    fn query(self: *LocalBackend, arena: std.mem.Allocator, io: Io, req: rest.Request) !json.Value {
        const label = req.params.identifier orelse "upload";
        const exclude: u32 = if (req.params.no_identity_match and req.params.identifier != null) olaf_cli_core.nameToId(label) else 0;
        const upload = try Upload.create(io, arena, req.body);
        defer upload.deinit();

        var out: Io.Writer.Allocating = .init(arena);
        const w = &out.writer;
        // Exact durations: the query objects round them to 0.001 s, and
        // `olaf rest query` derives fingerprints_per_second from them.
        var durations: std.ArrayList(f64) = .empty;
        try w.writeAll("{\"queries\":[");
        if (req.params.fragmented) {
            var it = try olaf_cli_threading.fragments(try olaf_cli_util_audio.getAudioDuration(arena, io, upload.path), self.config.fragment_duration_in_seconds);
            while (it.next()) |fragment| {
                if (durations.items.len > 0) try w.writeByte(',');
                try durations.append(arena, try self.queryOne(arena, io, w, upload.path, label, exclude, fragment));
            }
        } else {
            try durations.append(arena, try self.queryOne(arena, io, w, upload.path, label, exclude, null));
        }
        try w.writeAll("]}");
        const data = try json.parseFromSliceLeaky(json.Value, arena, out.written(), rest.envelope.parse_options);
        for (data.object.get("queries").?.array.items, durations.items) |*q, d| {
            try q.object.put(arena, "query_duration_seconds_exact", .{ .number_string = try std.fmt.allocPrint(arena, "{d:.6}", .{d}) });
        }
        return data;
    }

    /// Write one query object; returns the exact audio duration queried.
    fn queryOne(self: *LocalBackend, arena: std.mem.Allocator, io: Io, w: *Io.Writer, upload_path: []const u8, label: []const u8, exclude: u32, fragment: ?olaf_cli_threading.Fragment) !f64 {
        const raw = try olaf_cli_threading.TempRaw.create(io, arena, upload_path, self.config, fragment);
        defer raw.deinit();
        const q = try olaf_cli_session.queryCollectWithStats(arena, raw.path, label, self.config, exclude);
        try olaf_cli_output.formatQueryJson(w, .{
            .index = 0,
            .total = 1,
            .path = label,
            .offset = if (fragment) |f| f.start else 0,
        }, .{
            .fingerprints = q.stats.fingerprints,
            .audio_seconds = q.stats.audio_seconds,
            .cpu_seconds = q.stats.cpu_seconds,
        }, q.matches);
        return q.stats.audio_seconds;
    }
};

/// The uploaded audio in a temp file for ffmpeg to decode; deleted by deinit.
const Upload = struct {
    path: []const u8,
    io: Io,

    fn create(io: Io, arena: std.mem.Allocator, body: []const u8) !Upload {
        const path = try olaf_cli_threading.createTempPath(io, arena, ".upload");
        const file = try Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        errdefer Io.Dir.cwd().deleteFile(io, path) catch {};
        try file.writeStreamingAll(io, body);
        return .{ .path = path, .io = io };
    }

    fn deinit(self: Upload) void {
        Io.Dir.cwd().deleteFile(self.io, self.path) catch {};
    }
};
