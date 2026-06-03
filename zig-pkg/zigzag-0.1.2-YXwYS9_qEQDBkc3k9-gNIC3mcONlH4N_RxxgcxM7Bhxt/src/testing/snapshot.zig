//! Snapshot testing utilities.
//!
//! Lets tests assert that a rendered view matches a golden file on disk. When
//! a snapshot does not exist, it is written on the first run. Set the
//! environment variable `ZIGZAG_UPDATE_SNAPSHOTS=1` to overwrite existing
//! snapshots, e.g. after an intentional change:
//!
//!     ZIGZAG_UPDATE_SNAPSHOTS=1 zig build test
//!
//! Typical usage inside a test:
//!
//!     try zz.testing.expectSnapshot(
//!         std.testing.allocator,
//!         "tests/snapshots/welcome.snap",
//!         rendered_output,
//!     );

const std = @import("std");
const ansi = @import("../terminal/ansi.zig");

pub const SnapshotError = error{
    SnapshotMismatch,
} || std.fs.File.OpenError || std.fs.File.WriteError || std.mem.Allocator.Error;

pub const Options = struct {
    /// If true, the rendered output has ANSI CSI escape sequences stripped
    /// before comparison and before writing new snapshots. This produces
    /// stable golden files for components whose styling is decorative.
    strip_ansi: bool = true,
    /// Trailing spaces on each line are stripped before comparison. Helps
    /// when padding fluctuates between renders.
    trim_trailing_whitespace: bool = true,
};

/// Assert that `actual` matches the snapshot stored at `path`.
///
/// If the file does not exist, it is created with the current output and the
/// test passes. If the environment variable `ZIGZAG_UPDATE_SNAPSHOTS=1` is
/// set, the file is overwritten with the current output and the test passes.
/// Otherwise the stored and actual content must match byte-for-byte after
/// applying `Options`.
pub fn expectSnapshot(
    allocator: std.mem.Allocator,
    path: []const u8,
    actual: []const u8,
) SnapshotError!void {
    return expectSnapshotOpts(allocator, path, actual, .{});
}

pub fn expectSnapshotOpts(
    allocator: std.mem.Allocator,
    path: []const u8,
    actual: []const u8,
    opts: Options,
) SnapshotError!void {
    const normalized = try normalize(allocator, actual, opts);
    defer allocator.free(normalized);

    // Ensure parent directory exists so callers don't have to mkdir.
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }

    const update_env = std.posix.getenv("ZIGZAG_UPDATE_SNAPSHOTS");
    const update = update_env != null and update_env.?.len > 0 and !std.mem.eql(u8, update_env.?, "0");

    if (update) {
        try writeAll(path, normalized);
        return;
    }

    const existing = std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => {
            try writeAll(path, normalized);
            return;
        },
        else => return err,
    };
    defer allocator.free(existing);

    const existing_norm = try normalize(allocator, existing, opts);
    defer allocator.free(existing_norm);

    if (!std.mem.eql(u8, existing_norm, normalized)) {
        // Print a unified-ish diff to stderr so the mismatch is actionable.
        printDiff(path, existing_norm, normalized);
        return SnapshotError.SnapshotMismatch;
    }
}

fn writeAll(path: []const u8, contents: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    var buf: [4096]u8 = undefined;
    var w = file.writer(&buf);
    try w.interface.writeAll(contents);
    try w.interface.flush();
}

fn normalize(allocator: std.mem.Allocator, input: []const u8, opts: Options) ![]u8 {
    var work: []u8 = try allocator.dupe(u8, input);
    errdefer allocator.free(work);

    if (opts.strip_ansi) {
        const stripped = try stripAnsi(allocator, work);
        allocator.free(work);
        work = stripped;
    }

    if (opts.trim_trailing_whitespace) {
        const trimmed = try trimTrailingWhitespace(allocator, work);
        allocator.free(work);
        work = trimmed;
    }

    return work;
}

fn stripAnsi(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = try std.array_list.Managed(u8).initCapacity(allocator, input.len);
    errdefer out.deinit();

    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];
        if (c != 0x1b) {
            try out.append(c);
            i += 1;
            continue;
        }

        // ESC encountered. Consume the sequence.
        i += 1;
        if (i >= input.len) break;

        const next = input[i];
        if (next == '[') {
            // CSI: ESC [ ... final
            i += 1;
            while (i < input.len) {
                const b = input[i];
                i += 1;
                if ((b >= '@' and b <= '~')) break;
            }
        } else if (next == ']') {
            // OSC: ESC ] ... ST or BEL
            i += 1;
            while (i < input.len) {
                const b = input[i];
                if (b == 0x07) {
                    i += 1;
                    break;
                }
                if (b == 0x1b and i + 1 < input.len and input[i + 1] == '\\') {
                    i += 2;
                    break;
                }
                i += 1;
            }
        } else {
            // Two-byte ESC sequence (ESC Fe / Fp / Fs).
            i += 1;
        }
    }

    return out.toOwnedSlice();
}

fn trimTrailingWhitespace(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = try std.array_list.Managed(u8).initCapacity(allocator, input.len);
    errdefer out.deinit();

    var lines = std.mem.splitScalar(u8, input, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append('\n');
        first = false;
        var end = line.len;
        while (end > 0 and (line[end - 1] == ' ' or line[end - 1] == '\t' or line[end - 1] == '\r')) {
            end -= 1;
        }
        try out.appendSlice(line[0..end]);
    }
    return out.toOwnedSlice();
}

fn printDiff(path: []const u8, expected: []const u8, actual: []const u8) void {
    // Avoid allocating in diff path — just dump both snippets.
    const stderr = std.debug;
    stderr.print(
        "\nSnapshot mismatch: {s}\n" ++
            "  run with ZIGZAG_UPDATE_SNAPSHOTS=1 to update.\n" ++
            "--- expected ---\n{s}\n" ++
            "--- actual ---\n{s}\n" ++
            "----------------\n",
        .{ path, expected, actual },
    );
}

test "stripAnsi removes CSI and OSC" {
    const allocator = std.testing.allocator;
    const input = "\x1b[31mred\x1b[0m \x1b]0;title\x07plain";
    const stripped = try stripAnsi(allocator, input);
    defer allocator.free(stripped);
    try std.testing.expectEqualStrings("red plain", stripped);
}

test "trimTrailingWhitespace" {
    const allocator = std.testing.allocator;
    const out = try trimTrailingWhitespace(allocator, "hello   \nworld \t\n");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("hello\nworld\n", out);
}

test "expectSnapshot creates file when missing" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Change cwd to tmp so relative paths resolve there.
    var orig = try std.fs.cwd().openDir(".", .{});
    defer orig.close();
    try tmp.dir.setAsCwd();
    defer orig.setAsCwd() catch {};

    try expectSnapshot(allocator, "snap.txt", "hello world");
    try expectSnapshot(allocator, "snap.txt", "hello world");

    // Different content should mismatch.
    const err = expectSnapshot(allocator, "snap.txt", "hello there");
    try std.testing.expectError(SnapshotError.SnapshotMismatch, err);
}
