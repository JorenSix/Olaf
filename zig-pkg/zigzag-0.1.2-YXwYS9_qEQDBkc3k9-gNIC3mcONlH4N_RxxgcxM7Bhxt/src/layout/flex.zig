//! Constraint-based Flexbox layout engine for ZigZag TUI.
//!
//! Resolves sizing constraints and computes rectangular areas
//! for a list of flex items along a main axis (row or column),
//! with support for gaps, cross-axis alignment, main-axis
//! justification, and line wrapping.
//!
//! ## Example
//!
//! ```zig
//! const areas = try flex.layout(allocator, 80, 24, &.{
//!     .{ .constraint = .{ .percentage = 30 } },
//!     .{ .constraint = .{ .min = 10 } },
//!     .{ .constraint = .fill },
//! }, .{ .direction = .row, .gap = 1 });
//! ```

const std = @import("std");

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// A sizing constraint for one flex item.
pub const Constraint = union(enum) {
    /// Exactly `n` cells.
    fixed: u16,
    /// A percentage of total available space (0-100).
    percentage: u8,
    /// At least `n` cells (can grow to fill).
    min: u16,
    /// At most `n` cells (can shrink to fit).
    max: u16,
    /// Ratio: `num / den` of available space.
    ratio: struct { num: u16, den: u16 },
    /// Take all remaining space after fixed/percentage items.
    fill,
};

/// Main-axis direction.
pub const Direction = enum {
    row,
    column,
};

/// Cross-axis alignment.
pub const Alignment = enum {
    start,
    center,
    end,
    stretch,
};

/// Main-axis content distribution.
pub const Justify = enum {
    start,
    center,
    end,
    space_between,
    space_around,
    space_evenly,
};

/// Describes a single flex child.
pub const Item = struct {
    constraint: Constraint = .fill,
};

/// Layout options.
pub const FlexOptions = struct {
    direction: Direction = .row,
    gap: u16 = 0,
    alignment: Alignment = .stretch,
    justify: Justify = .start,
    wrap: bool = false,
};

/// An output rectangle (in cell coordinates).
pub const Rect = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,
};

// ---------------------------------------------------------------------------
// Core layout algorithm
// ---------------------------------------------------------------------------

/// Compute layout rectangles for `items` inside a container of
/// `total_width` x `total_height` cells.
///
/// Returns a slice of `Rect` allocated with `allocator`.
pub fn layout(
    allocator: std.mem.Allocator,
    total_width: u16,
    total_height: u16,
    items: []const Item,
    options: FlexOptions,
) ![]Rect {
    if (items.len == 0) {
        return try allocator.alloc(Rect, 0);
    }

    if (options.wrap) {
        return layoutWrapped(allocator, total_width, total_height, items, options);
    }

    return layoutLine(allocator, total_width, total_height, items, options, 0, 0);
}

/// Layout a single line of items (no wrapping).
fn layoutLine(
    allocator: std.mem.Allocator,
    total_width: u16,
    total_height: u16,
    items: []const Item,
    options: FlexOptions,
    origin_x: u16,
    origin_y: u16,
) ![]Rect {
    const n = items.len;
    const is_row = options.direction == .row;
    const main_total: u16 = if (is_row) total_width else total_height;
    const cross_total: u16 = if (is_row) total_height else total_width;

    // Total gap space
    const gap_count: u16 = if (n > 1) @intCast(n - 1) else 0;
    const total_gap: u16 = gap_count * options.gap;
    const avail: u16 = if (main_total > total_gap) main_total - total_gap else 0;

    // -- Phase 1: resolve constraints to sizes --------------------------------
    var sizes = try allocator.alloc(u16, n);
    defer allocator.free(sizes);

    var fill_count: u16 = 0;
    var used: u32 = 0;

    for (items, 0..) |item, i| {
        switch (item.constraint) {
            .fixed => |v| {
                sizes[i] = v;
                used += v;
            },
            .percentage => |pct| {
                const clamped: u32 = @min(pct, 100);
                const sz: u16 = @intCast((@as(u32, avail) * clamped) / 100);
                sizes[i] = sz;
                used += sz;
            },
            .min => |v| {
                sizes[i] = v;
                used += v;
            },
            .max => |v| {
                sizes[i] = v;
                used += v;
            },
            .ratio => |r| {
                const sz: u16 = if (r.den == 0) 0 else @intCast((@as(u32, avail) * r.num) / r.den);
                sizes[i] = sz;
                used += sz;
            },
            .fill => {
                sizes[i] = 0;
                fill_count += 1;
            },
        }
    }

    // -- Phase 2: distribute remaining space among fill items -----------------
    const remaining: u16 = if (avail > @as(u16, @intCast(@min(used, avail)))) avail - @as(u16, @intCast(@min(used, avail))) else 0;
    if (fill_count > 0 and remaining > 0) {
        const per_fill: u16 = remaining / fill_count;
        var leftover: u16 = remaining - per_fill * fill_count;
        for (items, 0..) |item, i| {
            if (item.constraint == .fill) {
                sizes[i] = per_fill;
                if (leftover > 0) {
                    sizes[i] += 1;
                    leftover -= 1;
                }
            }
        }
    }

    // Grow `min` items if there is leftover space
    if (fill_count == 0 and remaining > 0) {
        var min_count: u16 = 0;
        for (items) |item| {
            if (item.constraint == .min) min_count += 1;
        }
        if (min_count > 0) {
            const per_min: u16 = remaining / min_count;
            var leftover: u16 = remaining - per_min * min_count;
            for (items, 0..) |item, i| {
                if (item.constraint == .min) {
                    sizes[i] += per_min;
                    if (leftover > 0) {
                        sizes[i] += 1;
                        leftover -= 1;
                    }
                }
            }
        }
    }

    // Shrink `max` items so they don't exceed their cap
    for (items, 0..) |item, i| {
        if (item.constraint == .max) {
            const cap = item.constraint.max;
            if (sizes[i] > cap) sizes[i] = cap;
        }
    }

    // Clamp all sizes so total doesn't exceed available space
    {
        var sum: u32 = 0;
        for (sizes) |s| sum += s;
        if (sum > avail) {
            const scale_num: u32 = avail;
            const scale_den: u32 = sum;
            for (sizes, 0..) |_, i| {
                sizes[i] = @intCast((@as(u32, sizes[i]) * scale_num) / scale_den);
            }
        }
    }

    // -- Phase 3: compute positions using justification ----------------------
    var positions = try allocator.alloc(u16, n);
    defer allocator.free(positions);

    {
        var total_sizes: u32 = 0;
        for (sizes) |s| total_sizes += s;
        const total_content: u32 = total_sizes + total_gap;
        const free_space: u16 = if (main_total > @as(u16, @intCast(@min(total_content, main_total)))) main_total - @as(u16, @intCast(total_content)) else 0;

        var cursor: u16 = switch (options.justify) {
            .start => 0,
            .center => free_space / 2,
            .end => free_space,
            .space_between => 0,
            .space_around => 0,
            .space_evenly => 0,
        };

        // Compute per-item extra spacing for space_* modes
        var between_extra: u16 = 0;
        var before_first: u16 = 0;

        switch (options.justify) {
            .space_between => {
                if (n > 1) {
                    between_extra = free_space / @as(u16, @intCast(n - 1));
                }
            },
            .space_around => {
                const slot: u16 = free_space / @as(u16, @intCast(n));
                before_first = slot / 2;
                between_extra = slot;
                cursor = before_first;
            },
            .space_evenly => {
                const slot: u16 = free_space / @as(u16, @intCast(n + 1));
                before_first = slot;
                between_extra = slot;
                cursor = before_first;
            },
            else => {},
        }

        for (0..n) |i| {
            positions[i] = cursor;
            cursor += sizes[i];
            if (i < n - 1) {
                cursor += options.gap + between_extra;
            }
        }
    }

    // -- Phase 4: build output Rects -----------------------------------------
    var rects = try allocator.alloc(Rect, n);

    for (0..n) |i| {
        const main_pos = positions[i];
        const main_size = sizes[i];

        const cross_pos: u16 = 0;
        const cross_size: u16 = cross_total;

        if (is_row) {
            rects[i] = .{
                .x = origin_x + main_pos,
                .y = origin_y + cross_pos,
                .width = main_size,
                .height = cross_size,
            };
        } else {
            rects[i] = .{
                .x = origin_x + cross_pos,
                .y = origin_y + main_pos,
                .width = cross_size,
                .height = main_size,
            };
        }
    }

    return rects;
}

// ---------------------------------------------------------------------------
// Wrapped layout
// ---------------------------------------------------------------------------

fn layoutWrapped(
    allocator: std.mem.Allocator,
    total_width: u16,
    total_height: u16,
    items: []const Item,
    options: FlexOptions,
) ![]Rect {
    const is_row = options.direction == .row;
    const main_total: u16 = if (is_row) total_width else total_height;

    // First pass: figure out which items go on which line
    var lines = std.array_list.Managed(LineRange).init(allocator);
    defer lines.deinit();

    var line_start: usize = 0;
    var line_used: u32 = 0;

    for (items, 0..) |item, i| {
        const item_size = estimateSize(item.constraint, main_total);
        const gap_needed: u32 = if (i > line_start) options.gap else 0;

        if (line_used + gap_needed + item_size > main_total and i > line_start) {
            try lines.append(.{ .start = line_start, .end = i });
            line_start = i;
            line_used = item_size;
        } else {
            line_used += gap_needed + item_size;
        }
    }
    // Last line
    if (line_start < items.len) {
        try lines.append(.{ .start = line_start, .end = items.len });
    }

    const num_lines = lines.items.len;
    if (num_lines == 0) {
        return try allocator.alloc(Rect, 0);
    }

    const cross_total: u16 = if (is_row) total_height else total_width;
    const per_line: u16 = if (num_lines > 0) cross_total / @as(u16, @intCast(num_lines)) else cross_total;

    var rects = try allocator.alloc(Rect, items.len);

    var cross_cursor: u16 = 0;
    for (lines.items) |line| {
        const line_items = items[line.start..line.end];
        const line_main: u16 = if (is_row) total_width else per_line;
        const line_cross: u16 = per_line;
        const line_w: u16 = if (is_row) line_main else line_cross;
        const line_h: u16 = if (is_row) line_cross else line_main;
        const ox: u16 = if (is_row) 0 else cross_cursor;
        const oy: u16 = if (is_row) cross_cursor else 0;

        const line_rects = try layoutLine(allocator, line_w, line_h, line_items, options, ox, oy);
        defer allocator.free(line_rects);

        @memcpy(rects[line.start..line.end], line_rects);
        cross_cursor += per_line;
    }

    return rects;
}

const LineRange = struct {
    start: usize,
    end: usize,
};

fn estimateSize(constraint: Constraint, total: u16) u32 {
    return switch (constraint) {
        .fixed => |v| v,
        .percentage => |pct| (@as(u32, total) * @as(u32, @min(pct, 100))) / 100,
        .min => |v| v,
        .max => |v| v,
        .ratio => |r| if (r.den == 0) 0 else (@as(u32, total) * r.num) / r.den,
        .fill => 1, // minimum estimate for wrapping purposes
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "basic row layout" {
    const allocator = std.testing.allocator;
    const rects = try layout(allocator, 100, 24, &.{
        .{ .constraint = .{ .fixed = 20 } },
        .{ .constraint = .fill },
        .{ .constraint = .{ .fixed = 30 } },
    }, .{ .direction = .row });
    defer allocator.free(rects);

    try std.testing.expectEqual(@as(usize, 3), rects.len);
    try std.testing.expectEqual(@as(u16, 20), rects[0].width);
    try std.testing.expectEqual(@as(u16, 30), rects[2].width);
    try std.testing.expectEqual(@as(u16, 50), rects[1].width);
    try std.testing.expectEqual(@as(u16, 0), rects[0].x);
    try std.testing.expectEqual(@as(u16, 20), rects[1].x);
    try std.testing.expectEqual(@as(u16, 70), rects[2].x);
}

test "column layout" {
    const allocator = std.testing.allocator;
    const rects = try layout(allocator, 80, 40, &.{
        .{ .constraint = .{ .fixed = 3 } },
        .{ .constraint = .fill },
        .{ .constraint = .{ .fixed = 1 } },
    }, .{ .direction = .column });
    defer allocator.free(rects);

    try std.testing.expectEqual(@as(u16, 3), rects[0].height);
    try std.testing.expectEqual(@as(u16, 36), rects[1].height);
    try std.testing.expectEqual(@as(u16, 1), rects[2].height);
}

test "percentage constraint" {
    const allocator = std.testing.allocator;
    const rects = try layout(allocator, 100, 10, &.{
        .{ .constraint = .{ .percentage = 30 } },
        .{ .constraint = .{ .percentage = 70 } },
    }, .{ .direction = .row });
    defer allocator.free(rects);

    try std.testing.expectEqual(@as(u16, 30), rects[0].width);
    try std.testing.expectEqual(@as(u16, 70), rects[1].width);
}

test "gap spacing" {
    const allocator = std.testing.allocator;
    const rects = try layout(allocator, 100, 10, &.{
        .{ .constraint = .{ .fixed = 20 } },
        .{ .constraint = .{ .fixed = 20 } },
    }, .{ .direction = .row, .gap = 5 });
    defer allocator.free(rects);

    try std.testing.expectEqual(@as(u16, 0), rects[0].x);
    try std.testing.expectEqual(@as(u16, 25), rects[1].x);
}

test "ratio constraint" {
    const allocator = std.testing.allocator;
    const rects = try layout(allocator, 90, 10, &.{
        .{ .constraint = .{ .ratio = .{ .num = 1, .den = 3 } } },
        .{ .constraint = .{ .ratio = .{ .num = 2, .den = 3 } } },
    }, .{ .direction = .row });
    defer allocator.free(rects);

    try std.testing.expectEqual(@as(u16, 30), rects[0].width);
    try std.testing.expectEqual(@as(u16, 60), rects[1].width);
}

test "empty items" {
    const allocator = std.testing.allocator;
    const rects = try layout(allocator, 80, 24, &.{}, .{});
    defer allocator.free(rects);
    try std.testing.expectEqual(@as(usize, 0), rects.len);
}
