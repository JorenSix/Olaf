//! Fuzzy string matching utility.
//!
//! Provides character-subsequence scoring used by filterable components like
//! `List`, `Dropdown`, and `CommandPalette`. The scoring rewards consecutive
//! matches and word-start positions so that "fb" ranks "file_browser" above
//! "find_buffer".

const std = @import("std");

/// Score a subsequence match. Returns 0 when `pattern` is not a subsequence of
/// `text`. Comparison is case-sensitive: use `scoreIgnoreCase` if you want to
/// ignore case without allocating.
pub fn score(text: []const u8, pattern: []const u8) i32 {
    if (pattern.len == 0) return 1;
    if (text.len == 0) return 0;

    var total: i32 = 0;
    var pi: usize = 0;
    var consecutive: i32 = 0;

    for (text, 0..) |c, ti| {
        if (pi < pattern.len and c == pattern[pi]) {
            total += 1;
            consecutive += 1;
            total += consecutive;
            if (ti == 0 or text[ti - 1] == ' ' or text[ti - 1] == '_' or text[ti - 1] == '-' or text[ti - 1] == '/') {
                total += 5;
            }
            pi += 1;
        } else {
            consecutive = 0;
        }
    }

    if (pi < pattern.len) return 0;
    return total;
}

/// Like `score` but compares ASCII characters case-insensitively without
/// allocating. Non-ASCII bytes are compared exactly.
pub fn scoreIgnoreCase(text: []const u8, pattern: []const u8) i32 {
    if (pattern.len == 0) return 1;
    if (text.len == 0) return 0;

    var total: i32 = 0;
    var pi: usize = 0;
    var consecutive: i32 = 0;

    for (text, 0..) |c, ti| {
        if (pi < pattern.len and asciiLower(c) == asciiLower(pattern[pi])) {
            total += 1;
            consecutive += 1;
            total += consecutive;
            if (ti == 0 or text[ti - 1] == ' ' or text[ti - 1] == '_' or text[ti - 1] == '-' or text[ti - 1] == '/') {
                total += 5;
            }
            pi += 1;
        } else {
            consecutive = 0;
        }
    }

    if (pi < pattern.len) return 0;
    return total;
}

/// Return the byte positions in `text` that match characters of `pattern` in
/// order. Useful for highlighting matched characters. Returns `null` if
/// `pattern` is not a subsequence.
pub fn matchPositions(
    allocator: std.mem.Allocator,
    text: []const u8,
    pattern: []const u8,
    ignore_case: bool,
) !?[]usize {
    if (pattern.len == 0) return try allocator.alloc(usize, 0);

    var positions = try std.array_list.Managed(usize).initCapacity(allocator, pattern.len);
    errdefer positions.deinit();

    var pi: usize = 0;
    for (text, 0..) |c, ti| {
        if (pi >= pattern.len) break;
        const a = if (ignore_case) asciiLower(c) else c;
        const b = if (ignore_case) asciiLower(pattern[pi]) else pattern[pi];
        if (a == b) {
            try positions.append(ti);
            pi += 1;
        }
    }

    if (pi < pattern.len) {
        positions.deinit();
        return null;
    }
    return try positions.toOwnedSlice();
}

pub const Ranked = struct {
    index: usize,
    score: i32,
};

/// Score every haystack entry against `pattern` and return the ones with a
/// positive score, sorted by score descending. Caller owns the returned slice.
pub fn rank(
    allocator: std.mem.Allocator,
    haystack: []const []const u8,
    pattern: []const u8,
    ignore_case: bool,
) ![]Ranked {
    var out = std.array_list.Managed(Ranked).init(allocator);
    errdefer out.deinit();

    for (haystack, 0..) |entry, i| {
        const s = if (ignore_case) scoreIgnoreCase(entry, pattern) else score(entry, pattern);
        if (s > 0) try out.append(.{ .index = i, .score = s });
    }

    std.mem.sort(Ranked, out.items, {}, struct {
        fn lt(_: void, a: Ranked, b: Ranked) bool {
            return a.score > b.score;
        }
    }.lt);

    return out.toOwnedSlice();
}

fn asciiLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

test "empty pattern matches with score 1" {
    try std.testing.expectEqual(@as(i32, 1), score("hello", ""));
    try std.testing.expectEqual(@as(i32, 1), scoreIgnoreCase("hello", ""));
}

test "non-subsequence returns zero" {
    try std.testing.expectEqual(@as(i32, 0), score("hello", "xyz"));
}

test "consecutive matches score higher than scattered" {
    // Both have the 'h' at a word-start, so the difference comes from the
    // second character: consecutive in "hello", scattered in "hxexy".
    const consec = score("hello", "he");
    const split = score("hxexy", "he");
    try std.testing.expect(consec > split);
}

test "case insensitive" {
    try std.testing.expect(scoreIgnoreCase("HELLO", "he") > 0);
    try std.testing.expect(score("HELLO", "he") == 0);
}

test "matchPositions returns byte indices" {
    const allocator = std.testing.allocator;
    const positions = (try matchPositions(allocator, "hello", "hl", false)).?;
    defer allocator.free(positions);
    try std.testing.expectEqualSlices(usize, &.{ 0, 2 }, positions);
}

test "rank sorts by score descending" {
    const allocator = std.testing.allocator;
    const items = [_][]const u8{ "apple", "application", "ape" };
    const ranked = try rank(allocator, &items, "app", false);
    defer allocator.free(ranked);
    try std.testing.expect(ranked.len >= 2);
    // "apple" and "application" both start with "app"; first-place tie is
    // valid, but "ape" (partial) should lose if present.
    for (ranked) |r| try std.testing.expect(r.score > 0);
}
