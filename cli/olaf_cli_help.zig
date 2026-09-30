//! Command help: descriptions, usage lines and option tables, word-wrapped
//! to the terminal width with hanging indents.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

/// One documented option: `name` as typed (e.g. "-f, --force") and what it does.
pub const Option = struct {
    name: []const u8,
    text: []const u8,
};

/// What `olaf help` prints for one command.
pub const Help = struct {
    /// Full command name, e.g. "rest store".
    name: []const u8,
    /// Prose; each '\n' starts a new line, every line is wrapped on its own.
    description: []const u8,
    /// Everything after "olaf <name> ".
    usage: []const u8,
    options: []const Option = &.{},
};

/// Width when stdout is not a terminal (pipes, files, tests).
pub const default_width = 80;
/// Wider lines are hard to read, even when the terminal allows them.
const max_width = 100;
const min_width = 40;

const description_indent = 2;
const option_indent = 4;
/// Option names longer than this put their text on the next line.
const max_option_column = 28;

/// The column count of the terminal on stdout, clamped to a readable range;
/// `default_width` when stdout is not a terminal.
pub fn terminalWidth() usize {
    if (builtin.os.tag == .windows or !builtin.link_libc) return default_width;
    var ws: std.posix.winsize = undefined;
    const req: c_int = @bitCast(@as(c_uint, @intCast(std.c.T.IOCGWINSZ)));
    if (std.c.ioctl(std.posix.STDOUT_FILENO, req, &ws) != 0 or ws.col == 0) return default_width;
    return std.math.clamp(@as(usize, ws.col), min_width, max_width);
}

/// A command entry of `olaf help`: name, description, usage and options.
pub fn writeCommand(w: *Io.Writer, h: Help, width: usize) Io.Writer.Error!void {
    try w.print("{s}\n", .{h.name});
    var lines = std.mem.splitScalar(u8, h.description, '\n');
    while (lines.next()) |line| {
        try w.splatByteAll(' ', description_indent);
        try writeWrapped(w, line, description_indent, description_indent, width, false);
        try w.writeByte('\n');
    }
    try w.splatByteAll(' ', description_indent);
    try writeUsage(w, h.name, h.usage, description_indent, width);
    try writeOptions(w, h.options, width);
}

/// "olaf <name> <usage>\n", continuation lines aligned after "olaf <name> "
/// and broken only between bracketed groups. `col` is the current column.
pub fn writeUsage(w: *Io.Writer, name: []const u8, usage: []const u8, col: usize, width: usize) Io.Writer.Error!void {
    try w.print("olaf {s}", .{name});
    const prefix = col + "olaf ".len + name.len;
    if (usage.len > 0) {
        try w.writeByte(' ');
        // A deep hanging indent would leave too little room on narrow terminals.
        const indent = if (prefix + 1 <= width / 2) prefix + 1 else col + 4;
        try writeWrapped(w, usage, prefix + 1, indent, width, true);
    }
    try w.writeByte('\n');
}

/// The option table: names in a column, texts wrapped beside them.
pub fn writeOptions(w: *Io.Writer, options: []const Option, width: usize) Io.Writer.Error!void {
    var longest: usize = 0;
    for (options) |o| {
        if (o.name.len <= max_option_column) longest = @max(longest, o.name.len);
    }
    const text_col = option_indent + longest + 2;
    for (options) |o| {
        try w.splatByteAll(' ', option_indent);
        try w.writeAll(o.name);
        if (o.name.len > longest) {
            try w.writeByte('\n');
            try w.splatByteAll(' ', text_col);
        } else {
            try w.splatByteAll(' ', text_col - option_indent - o.name.len);
        }
        try writeWrapped(w, o.text, text_col, text_col, width, false);
        try w.writeByte('\n');
    }
}

/// Write `text` word by word starting at column `col`, breaking lines before
/// `width` and indenting continuation lines by `indent`. With `groups`,
/// spaces inside [...] and <...> do not break. A word wider than the line
/// is written whole.
fn writeWrapped(w: *Io.Writer, text: []const u8, col_start: usize, indent: usize, width: usize, groups: bool) Io.Writer.Error!void {
    var col = col_start;
    var first = true;
    var rest = std.mem.trim(u8, text, " ");
    while (rest.len > 0) {
        const end = wordEnd(rest, groups);
        const word = rest[0..end];
        rest = std.mem.trimStart(u8, rest[end..], " ");
        if (!first and col + 1 + word.len > width) {
            try w.writeByte('\n');
            try w.splatByteAll(' ', indent);
            col = indent;
        } else if (!first) {
            try w.writeByte(' ');
            col += 1;
        }
        try w.writeAll(word);
        col += word.len;
        first = false;
    }
}

fn wordEnd(s: []const u8, groups: bool) usize {
    var depth: usize = 0;
    for (s, 0..) |ch, i| switch (ch) {
        '[', '<' => if (groups) {
            depth += 1;
        },
        ']', '>' => if (groups) {
            depth -|= 1;
        },
        ' ' => if (depth == 0) return i,
        else => {},
    };
    return s.len;
}

fn render(h: Help, width: usize) ![]u8 {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer out.deinit();
    try writeCommand(&out.writer, h, width);
    return out.toOwnedSlice();
}

test "help wraps to the width with hanging indents" {
    const out = try render(.{
        .name = "store",
        .description = "Extracts and stores fingerprints into an index.\nAlready indexed files are skipped.",
        .usage = "[-f] [--threads n] [audio_file...] | --with-ids [[audio_file audio_identifier] ...]",
        .options = &.{
            .{ .name = "-f, --force", .text = "Re-store files that are already indexed." },
            .{ .name = "--threads n", .text = "The number of threads to use." },
        },
    }, 40);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(
        \\store
        \\  Extracts and stores fingerprints into
        \\  an index.
        \\  Already indexed files are skipped.
        \\  olaf store [-f] [--threads n]
        \\             [audio_file...] |
        \\             --with-ids
        \\             [[audio_file audio_identifier] ...]
        \\    -f, --force  Re-store files that are
        \\                 already indexed.
        \\    --threads n  The number of threads
        \\                 to use.
        \\
    , out);
}

test "a long option name puts its text on the next line" {
    const out = try render(.{
        .name = "x",
        .description = "D.",
        .usage = "",
        .options = &.{
            .{ .name = "-a", .text = "A." },
            .{ .name = "--a-very-long-option-name <with|values>", .text = "B." },
        },
    }, 80);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(
        \\x
        \\  D.
        \\  olaf x
        \\    -a  A.
        \\    --a-very-long-option-name <with|values>
        \\        B.
        \\
    , out);
}

test "every line fits the width" {
    const out = try render(.{
        .name = "rest serve-lb",
        .description = "Serve the REST API on rest_lb_listen (default 127.0.0.1:9920), answered by the olaf rest serve instances in rest_lb_backends.",
        .usage = "[url] [--threshold n] [--threads n] [--format <json|text>] [audio_file...] | --with-ids [[audio_file audio_identifier]...]",
        .options = &.{.{ .name = "--listen host:port|port", .text = "Listen there instead of rest_lb_listen (a port alone: 127.0.0.1)." }},
    }, 50);
    defer std.testing.allocator.free(out);
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        // The one unbreakable usage group is the only allowed overflow.
        if (std.mem.indexOf(u8, line, "[[audio_file") != null) continue;
        try std.testing.expect(line.len <= 50);
    }
}
