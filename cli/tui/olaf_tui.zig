const std = @import("std");
const zz = @import("zigzag");

const olaf_cli_config = @import("../olaf_cli_config.zig");
const olaf_cli_util = @import("../olaf_cli_util.zig");
const olaf_cli_util_audio = @import("../olaf_cli_util_audio.zig");
const olaf_cli_bridge = @import("../olaf_cli_bridge.zig");
const olaf_cli_threading = @import("../olaf_cli_threading.zig");

const max_log_lines = 200;

/// A queued operation, executed on the next tick so the UI can paint a
/// "running…" frame before the (blocking) work runs.
const PendingOp = enum { store, query, fragmented_query };

const Model = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *const olaf_cli_config.Config,

    picker: zz.components.FilePicker,
    stats: ?olaf_cli_bridge.Stats,

    // Bounded ring of log lines shown in the right column. Each line is owned.
    log_lines: std.ArrayList([]const u8),

    running: bool,
    pending: ?PendingOp,
    pending_path: ?[]const u8,
    spinner_frame: usize,

    pub const Msg = union(enum) {
        key: zz.KeyEvent,
        tick: struct { timestamp: u64, delta: u64 },
    };

    pub fn init(self: *Model, ctx: *zz.Context) zz.Cmd(Msg) {
        _ = self;
        _ = ctx;
        // Model fields are populated by `prepare` before run(); init is a no-op.
        return .none;
    }

    pub fn update(self: *Model, msg: Msg, ctx: *zz.Context) zz.Cmd(Msg) {
        switch (msg) {
            .tick => {
                if (self.running) {
                    self.spinner_frame +%= 1;
                    if (self.pending) |op| {
                        self.pending = null;
                        self.runOp(op);
                        self.running = false;
                        self.refreshStats();
                    }
                    return .none;
                }
            },
            .key => |k| {
                switch (k.key) {
                    .char => |c| switch (c) {
                        'Q', 'q' => {
                            if (c == 'Q') return .quit;
                            return self.beginOp(.query);
                        },
                        's', 'S' => return self.beginOp(.store),
                        'f', 'F' => return self.beginOp(.fragmented_query),
                        'j' => {
                            _ = self.picker.handleKey(self.io, k) catch {};
                            return .none;
                        },
                        'k' => {
                            _ = self.picker.handleKey(self.io, k) catch {};
                            return .none;
                        },
                        else => {},
                    },
                    .escape => return .quit,
                    .up, .down, .enter, .backspace => {
                        _ = self.picker.handleKey(self.io, k) catch {};
                        return .none;
                    },
                    else => {},
                }
            },
        }
        _ = ctx;
        return .none;
    }

    /// Queue an operation on the currently-selected file and ask for a quick
    /// tick so the UI paints "running…" before the blocking work runs.
    fn beginOp(self: *Model, op: PendingOp) zz.Cmd(Msg) {
        if (self.running) return .none;

        // selectCurrent navigates into directories and only returns true for
        // a real file selection.
        const is_file = self.picker.selectCurrent(self.io) catch return .none;
        if (!is_file) return .none;
        const selected = self.picker.getSelected() orelse return .none;

        // Own a copy of the path; the picker may free its selected_path later.
        const path_copy = self.allocator.dupe(u8, selected) catch return .none;
        self.pending_path = path_copy;
        self.pending = op;
        self.running = true;
        self.spinner_frame = 0;

        const label = switch (op) {
            .store => "Storing",
            .query => "Querying",
            .fragmented_query => "Fragmented query",
        };
        self.appendLog("{s}: {s}", .{ label, std.fs.path.basename(path_copy) });
        return zz.Cmd(Msg).tickMs(1);
    }

    fn runOp(self: *Model, op: PendingOp) void {
        const path = self.pending_path orelse return;
        defer {
            self.allocator.free(path);
            self.pending_path = null;
        }

        switch (op) {
            .store => self.runStore(path),
            .query => self.runQuery(path),
            .fragmented_query => self.runFragmentedQuery(path),
        }
    }

    fn runStore(self: *Model, path: []const u8) void {
        const raw = self.toRaw(path) catch |e| {
            self.appendLog("  transcode failed: {s}", .{@errorName(e)});
            return;
        };
        defer self.cleanupRaw(raw);

        const result = olaf_cli_bridge.olaf_store_collect(self.allocator, raw, path, self.config) catch |e| {
            self.appendLog("  store failed: {s}", .{@errorName(e)});
            return;
        };
        const rt: f64 = if (result.cpu_seconds > 0) result.audio_seconds / result.cpu_seconds else 0;
        self.appendLog("  Stored {s}", .{std.fs.path.basename(path)});
        self.appendLog("  {d:.1}s audio in {d:.2}s = {d:.0}x realtime", .{ result.audio_seconds, result.cpu_seconds, rt });
        self.appendLog("  {d} fingerprints  id={d}", .{ result.fingerprints, result.internal_id });
    }

    fn runQuery(self: *Model, path: []const u8) void {
        const raw = self.toRaw(path) catch |e| {
            self.appendLog("  transcode failed: {s}", .{@errorName(e)});
            return;
        };
        defer self.cleanupRaw(raw);

        const matches = olaf_cli_bridge.olaf_query_collect(self.allocator, path, raw, path, self.config, 0) catch |e| {
            self.appendLog("  query failed: {s}", .{@errorName(e)});
            return;
        };
        defer olaf_cli_bridge.freeQueryMatches(self.allocator, matches);

        if (matches.len == 0) {
            self.appendLog("  no matches", .{});
            return;
        }
        self.logBestMatch(matches, null);
    }

    fn runFragmentedQuery(self: *Model, path: []const u8) void {
        const total = olaf_cli_util_audio.getAudioDuration(self.allocator, self.io, path) catch |e| {
            self.appendLog("  duration probe failed: {s}", .{@errorName(e)});
            return;
        };
        const frag_len: f32 = @floatFromInt(self.config.fragment_duration_in_seconds);
        var frag_start: f32 = 0;
        while (frag_start < total) : (frag_start += frag_len) {
            const this_len = @min(frag_len, total - frag_start);
            const frag_end = frag_start + this_len;

            const raw = olaf_cli_threading.createTempRawPath(self.io, self.allocator) catch |e| {
                self.appendLog("  frag {d:.0}-{d:.0}s: temp failed: {s}", .{ frag_start, frag_end, @errorName(e) });
                continue;
            };
            defer self.cleanupRaw(raw);

            olaf_cli_util_audio.convertAudioWithOptions(self.allocator, self.io, path, raw, .{
                .sample_rate = self.config.target_sample_rate,
                .start = frag_start,
                .duration = this_len,
            }) catch |e| {
                self.appendLog("  frag {d:.0}-{d:.0}s: transcode failed: {s}", .{ frag_start, frag_end, @errorName(e) });
                continue;
            };

            const matches = olaf_cli_bridge.olaf_query_collect(self.allocator, path, raw, path, self.config, 0) catch |e| {
                self.appendLog("  frag {d:.0}-{d:.0}s: query failed: {s}", .{ frag_start, frag_end, @errorName(e) });
                continue;
            };
            defer olaf_cli_bridge.freeQueryMatches(self.allocator, matches);

            const window = FragWindow{ .start = frag_start, .end = frag_end };
            if (matches.len == 0) {
                self.appendLog("  frag {d:.0}-{d:.0}s: no match", .{ frag_start, frag_end });
            } else {
                self.logBestMatch(matches, window);
            }
        }
    }

    const FragWindow = struct { start: f32, end: f32 };

    /// Pick the highest-scoring match, look up its metadata, and emit a
    /// summarized block. When `frag` is set the output is prefixed with the
    /// fragment window. Falls back to id + raw times when metadata is missing.
    fn logBestMatch(self: *Model, matches: []olaf_cli_bridge.QueryMatch, frag: ?FragWindow) void {
        var best = matches[0];
        var distinct = std.AutoHashMap(u32, void).init(self.allocator);
        defer distinct.deinit();
        for (matches) |m| {
            distinct.put(m.match_identifier, {}) catch {};
            if (m.match_count > best.match_count) best = m;
        }
        const others: usize = if (distinct.count() > 0) distinct.count() - 1 else 0;

        const prefix: []const u8 = if (frag) |w| blk: {
            break :blk std.fmt.allocPrint(self.allocator, "frag {d:.0}-{d:.0}s: ", .{ w.start, w.end }) catch "";
        } else "";
        defer if (frag != null and prefix.len > 0) self.allocator.free(prefix);

        const meta = olaf_cli_bridge.olaf_lookup_meta(self.allocator, self.config, best.match_identifier) catch null;
        if (meta) |md| {
            defer self.allocator.free(md.path);
            self.appendLog("  {s}Match: {s}  (id {d})", .{ prefix, std.fs.path.basename(md.path), best.match_identifier });
            self.appendLog("  Ref length: {d:.1}s   score: {d} fp", .{ md.duration, best.match_count });
            self.appendLog("  Query {d:.1}-{d:.1}s -> ref {d:.1}-{d:.1}s", .{
                best.query_start, best.query_stop, best.reference_start, best.reference_stop,
            });
            self.appendBlockBar(best.reference_start, best.reference_stop, md.duration);
            if (others > 0) self.appendLog("  (+{d} other matches)", .{others});
        } else {
            self.appendLog("  {s}Match id={d}  score {d} fp", .{ prefix, best.match_identifier, best.match_count });
            self.appendLog("  Query {d:.1}-{d:.1}s -> ref {d:.1}-{d:.1}s", .{
                best.query_start, best.query_stop, best.reference_start, best.reference_stop,
            });
            if (others > 0) self.appendLog("  (+{d} other matches)", .{others});
        }
    }

    /// Render a fixed-width ASCII bar marking [region_lo, region_hi] within
    /// [0, total], plus an axis line with 0 and total labels.
    fn appendBlockBar(self: *Model, region_lo: f32, region_hi: f32, total: f32) void {
        const width: usize = 28;
        if (total <= 0) return;
        var buf: [width + 2]u8 = undefined;
        buf[0] = '[';
        buf[width + 1] = ']';
        const lo_frac = std.math.clamp(region_lo / total, 0, 1);
        const hi_frac = std.math.clamp(region_hi / total, 0, 1);
        const lo_cell: usize = @intFromFloat(lo_frac * @as(f32, @floatFromInt(width)));
        var hi_cell: usize = @intFromFloat(hi_frac * @as(f32, @floatFromInt(width)));
        if (hi_cell <= lo_cell) hi_cell = lo_cell + 1;
        if (hi_cell > width) hi_cell = width;
        var i: usize = 0;
        while (i < width) : (i += 1) {
            buf[i + 1] = if (i >= lo_cell and i < hi_cell) '#' else '.';
        }
        self.appendLog("  {s}", .{buf[0 .. width + 2]});
        self.appendLog("  0s -> {d:.0}s", .{total});
    }

    fn toRaw(self: *Model, path: []const u8) ![]u8 {
        const raw = try olaf_cli_threading.createTempRawPath(self.io, self.allocator);
        errdefer self.allocator.free(raw);
        try olaf_cli_util_audio.convertToRaw(self.allocator, self.io, path, raw, self.config.target_sample_rate);
        return raw;
    }

    fn cleanupRaw(self: *Model, raw: []u8) void {
        std.Io.Dir.cwd().deleteFile(self.io, raw) catch {};
        self.allocator.free(raw);
    }

    fn refreshStats(self: *Model) void {
        self.stats = olaf_cli_bridge.olaf_stats_struct(self.allocator, self.config) catch null;
    }

    fn appendLog(self: *Model, comptime fmt: []const u8, args: anytype) void {
        const line = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        if (self.log_lines.items.len >= max_log_lines) {
            self.allocator.free(self.log_lines.orderedRemove(0));
        }
        self.log_lines.append(self.allocator, line) catch {
            self.allocator.free(line);
        };
    }

    pub fn view(self: *Model, ctx: *const zz.Context) []const u8 {
        const a = ctx.allocator; // frame allocator, reset each tick
        const total_h = ctx.height;

        // Reserve 2 rows for the trailing blank + status line; floor so a tiny
        // terminal never underflows.
        const body_h: usize = if (total_h > 3) total_h - 2 else 3;

        // Bound the file browser to body_h rows so it scrolls internally
        // instead of growing the frame past the terminal.
        self.picker.height = @intCast(body_h);

        const left = self.picker.view(a) catch "(file browser unavailable)";

        // Right-column width budget: terminal minus the widest left line minus
        // the 2-space separator. Log lines are truncated to this so a long
        // match line never wraps and pushes the browser off-screen.
        const left_w = maxLineWidth(left);
        const sep_w: usize = 2;
        const right_w: usize = if (ctx.width > left_w + sep_w)
            @as(usize, ctx.width) - left_w - sep_w
        else
            20;

        const right = self.renderRight(a, body_h, right_w) catch "(stats unavailable)";

        const columns = zz.join.horizontal(a, .top, &.{ left, "  ", right }) catch left;

        const status = self.renderStatus(a) catch "";
        return zz.join.vertical(a, .left, &.{ columns, status }) catch columns;
    }

    fn renderRight(self: *const Model, a: std.mem.Allocator, body_h: usize, right_w: usize) ![]const u8 {
        var result: std.Io.Writer.Allocating = .init(a);
        const w = &result.writer;

        // Header: 7 rows (Database, ----, 4 stat lines, blank).
        try w.writeAll("Database\n");
        try w.writeAll("--------\n");
        if (self.stats) |s| {
            const fps_per_s: f64 = if (s.total_duration > 0)
                @as(f64, @floatFromInt(s.total_fingerprints)) / s.total_duration
            else
                0.0;
            try w.print("Songs:        {d}\n", .{s.song_count});
            try w.print("Duration:     {d:.1}s\n", .{s.total_duration});
            try w.print("Fingerprints: {d}\n", .{s.total_fingerprints});
            try w.print("Avg fp/s:     {d:.1}\n", .{fps_per_s});
        } else {
            try w.writeAll("(no statistics)\n\n\n\n");
        }
        try w.writeAll("\n");
        var rows_written: usize = 7;

        // Spinner: 2 rows, only while an op runs.
        if (self.running) {
            const frames = [_][]const u8{ "|", "/", "-", "\\" };
            try w.print("{s} working...\n\n", .{frames[self.spinner_frame % frames.len]});
            rows_written += 2;
        }

        // Results header: 2 rows.
        try w.writeAll("Results\n");
        try w.writeAll("-------\n");
        rows_written += 2;

        // Show the most recent lines that fit in the remaining body height.
        const log_rows: usize = if (body_h > rows_written) body_h - rows_written else 0;
        const lines = self.log_lines.items;
        const start: usize = if (lines.len > log_rows) lines.len - log_rows else 0;
        const shown = lines[start..];
        for (shown) |line| {
            try w.writeAll(truncateCols(line, right_w));
            try w.writeAll("\n");
        }
        rows_written += shown.len;

        // Pad the block to exactly body_h rows so join.horizontal does not pad
        // asymmetrically and the status line stays pinned at the bottom.
        while (rows_written < body_h) : (rows_written += 1) {
            try w.writeAll("\n");
        }

        return result.toOwnedSlice();
    }

    fn renderStatus(self: *const Model, a: std.mem.Allocator) ![]const u8 {
        _ = self;
        return std.fmt.allocPrint(a, "\n s store  q query  f fragmented query  ↑↓/jk move  enter open  Q quit", .{});
    }

    pub fn deinit(self: *Model) void {
        self.picker.deinit();
        for (self.log_lines.items) |line| self.allocator.free(line);
        self.log_lines.deinit(self.allocator);
        if (self.pending_path) |p| self.allocator.free(p);
    }
};

/// Widest line in `block`, measured in Unicode codepoints (a closer proxy for
/// display columns than bytes when the picker emits multi-byte glyphs/icons).
fn maxLineWidth(block: []const u8) usize {
    var max: usize = 0;
    var it = std.mem.splitScalar(u8, block, '\n');
    while (it.next()) |line| {
        const cols = std.unicode.utf8CountCodepoints(line) catch line.len;
        if (cols > max) max = cols;
    }
    return max;
}

/// Truncate `line` to at most `max_cols` codepoints, returning a sub-slice that
/// ends on a valid UTF-8 boundary so a long match line never wraps.
fn truncateCols(line: []const u8, max_cols: usize) []const u8 {
    var cols: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        const len = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
        if (cols >= max_cols) return line[0..i];
        i += len;
        cols += 1;
    }
    return line;
}

/// Launch the no-args TUI. Owns its own zigzag program lifecycle.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    config: *const olaf_cli_config.Config,
) !void {
    var program = zz.Program(Model).init(allocator, io, environ_map);
    defer program.deinit();

    // Build the model state, then hand it to the program before run().
    try prepare(&program.model, allocator, io, config);

    try program.run();
}

fn prepare(
    model: *Model,
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *const olaf_cli_config.Config,
) !void {
    var picker = zz.components.FilePicker.init(allocator);
    picker.allowed_extensions = config.allowed_audio_file_extensions;
    if (config.home) |h| picker.setHomePath(h);
    picker.focus();

    // The picker navigates with absolute paths (openDirAbsolute), so resolve
    // the current working directory to an absolute path first.
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.Io.Dir.cwd().realPathFile(io, ".", &cwd_buf);
    try picker.navigate(io, cwd_buf[0..cwd_len]);

    model.* = .{
        .allocator = allocator,
        .io = io,
        .config = config,
        .picker = picker,
        .stats = olaf_cli_bridge.olaf_stats_struct(allocator, config) catch null,
        .log_lines = .empty,
        .running = false,
        .pending = null,
        .pending_path = null,
        .spinner_frame = 0,
    };
}
