const std = @import("std");
const print = std.debug.print;
const Thread = std.Thread;
const time = std.time;
const Atomic = std.atomic.Value;
const Random = std.Random;
const Mutex = std.Thread.Mutex;

// Maximum number of concurrent worker threads
const MAX_WORKERS = 3;

// List of files to process
const FILE_LIST = [_][]const u8{
    "data_export_2024.csv",
    "user_analytics.json",
    "system_logs.txt",
    "backup_archive.tar.gz",
    "config_settings.xml",
    "report_summary.pdf",
    "database_dump.sql",
    "access_logs.txt",
    "transaction_history.csv",
};

// Worker status enum
const WorkerStatus = enum(u8) {
    waiting,
    processing,
    completed,
    failed,
};

// Worker state structure
const WorkerState = struct {
    id: u32,
    filename: []const u8,
    status: Atomic(WorkerStatus),
    progress: Atomic(u32),
    total_ms: u32,
    start_time: i64,

    fn init(id: u32, filename: []const u8, total_ms: u32) WorkerState {
        return .{
            .id = id,
            .filename = filename,
            .status = Atomic(WorkerStatus).init(.waiting),
            .progress = Atomic(u32).init(0),
            .total_ms = total_ms,
            .start_time = 0,
        };
    }
};

// Work queue for managing files to process
const WorkQueue = struct {
    workers: []WorkerState,
    next_index: Atomic(usize),
    active_count: Atomic(u32),

    fn init(workers: []WorkerState) WorkQueue {
        return .{
            .workers = workers,
            .next_index = Atomic(usize).init(0),
            .active_count = Atomic(u32).init(0),
        };
    }

    fn getNext(self: *WorkQueue) ?*WorkerState {
        while (true) {
            const current = self.next_index.load(.acquire);
            if (current >= self.workers.len) {
                return null;
            }

            if (self.next_index.cmpxchgWeak(current, current + 1, .acq_rel, .acquire)) |_| {
                // Failed to update, try again
                continue;
            } else {
                // Successfully claimed this index
                _ = self.active_count.fetchAdd(1, .acq_rel);
                return &self.workers[current];
            }
        }
    }

    fn markComplete(self: *WorkQueue) void {
        _ = self.active_count.fetchSub(1, .acq_rel);
    }
};

// Global flag to control the display thread
var display_running = Atomic(bool).init(true);

// ANSI escape codes for terminal control
const ESC = "\x1B[";
const CLEAR_LINE = ESC ++ "2K";
const MOVE_UP = ESC ++ "1A";
const MOVE_DOWN = ESC ++ "1B";
const HIDE_CURSOR = ESC ++ "?25l";
const SHOW_CURSOR = ESC ++ "?25h";
const SAVE_CURSOR = ESC ++ "s";
const RESTORE_CURSOR = ESC ++ "u";

// Progress display function
fn displayProgress(workers: []WorkerState, queue: *WorkQueue) void {
    const spinner_chars = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
    var spinner_idx: usize = 0;

    // Hide cursor for cleaner display
    print("{s}", .{HIDE_CURSOR});

    // Reserve space for max workers + completed + status line
    var i: usize = 0;
    while (i < MAX_WORKERS + 2) : (i += 1) {
        print("\n", .{});
    }

    while (display_running.load(.acquire)) {
        var lines_printed: usize = 0;

        // Move cursor up to start
        i = 0;
        while (i < MAX_WORKERS + 2) : (i += 1) {
            print("{s}", .{MOVE_UP});
        }

        // First show files currently being processed
        for (workers) |*worker| {
            const status = worker.status.load(.acquire);
            if (status == .processing) {
                const progress = worker.progress.load(.acquire);
                print("{s}\r", .{CLEAR_LINE});

                const bar_width = 20;
                const filled = (progress * bar_width) / 100;

                print("  {s} [", .{
                    spinner_chars[spinner_idx % spinner_chars.len],
                });

                // Print progress bar
                var j: usize = 0;
                while (j < filled) : (j += 1) {
                    print("█", .{});
                }
                while (j < bar_width) : (j += 1) {
                    print("░", .{});
                }

                print("] {d: >3}% {s}\n", .{ progress, worker.filename });
                lines_printed += 1;
            }
        }

        // Fill remaining space with completed files (most recent first)
        var completed_count: usize = 0;
        var idx: usize = workers.len;
        while (idx > 0 and lines_printed < MAX_WORKERS) : (idx -= 1) {
            const worker = &workers[idx - 1];
            const status = worker.status.load(.acquire);
            if (status == .completed) {
                print("{s}\r", .{CLEAR_LINE});
                print("  ✓ [████████████████████] 100% {s}\n", .{worker.filename});
                lines_printed += 1;
                completed_count += 1;
            }
        }

        // Clear any remaining lines
        while (lines_printed < MAX_WORKERS) : (lines_printed += 1) {
            print("{s}\r\n", .{CLEAR_LINE});
        }

        // Count total completed
        var total_completed: usize = 0;
        for (workers) |*worker| {
            if (worker.status.load(.acquire) == .completed) {
                total_completed += 1;
            }
        }

        // Display status summary
        const active = queue.active_count.load(.acquire);
        const queued = queue.next_index.load(.acquire);
        const remaining = workers.len - queued;

        print("{s}\r", .{CLEAR_LINE});
        print("──────────────────────────────────────────────────\n", .{});
        print("{s}\r", .{CLEAR_LINE});
        print("  Active: {d}/{d} | Completed: {d}/{d} | Remaining: {d}", .{
            active,
            MAX_WORKERS,
            total_completed,
            workers.len,
            remaining,
        });
        print("\n", .{});

        // Update spinner
        spinner_idx += 1;

        // Small delay for smooth animation
        time.sleep(80 * time.ns_per_ms);
    }

    // Show cursor again
    print("{s}", .{SHOW_CURSOR});
}

// Process a single file
fn processFile(worker: *WorkerState) void {
    var prng = std.Random.DefaultPrng.init(@intCast(time.timestamp() + worker.id));
    var rng = prng.random();

    // Update status to processing
    worker.status.store(.processing, .release);
    worker.start_time = time.milliTimestamp();

    // Simulate file processing with progress updates
    const steps = 20;
    const step_duration = worker.total_ms / steps;

    var i: u32 = 0;
    while (i < steps) : (i += 1) {
        // Update progress
        const progress = ((i + 1) * 100) / steps;
        worker.progress.store(progress, .release);

        // Simulate work with some variability
        const variation = rng.intRangeAtMost(i32, -50, 50);
        const sleep_ms = @as(u32, @intCast(@max(0, @as(i32, @intCast(step_duration)) + variation)));
        time.sleep(sleep_ms * time.ns_per_ms);
    }

    // Mark as completed
    worker.status.store(.completed, .release);
}

// Worker thread function that processes files from the queue
fn workerThread(queue: *WorkQueue) void {
    while (queue.getNext()) |worker| {
        processFile(worker);
        queue.markComplete();
    }
}

pub fn main() !void {
    if (MAX_WORKERS == 1) {
        try runSingleThreaded(&FILE_LIST);
    } else {
        try runMultiThreaded(&FILE_LIST);
    }
}

// Single-threaded mode with progress display
fn runSingleThreaded(filenames: []const []const u8) !void {
    print("🚀 Starting file processing in single-threaded mode...\n\n", .{});

    var prng = std.Random.DefaultPrng.init(@intCast(time.timestamp()));
    var rng = prng.random();

    const spinner_chars = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
    var spinner_idx: usize = 0;

    // Hide cursor
    print("{s}", .{HIDE_CURSOR});

    // Process each file sequentially
    for (filenames, 0..) |filename, idx| {
        const process_time = rng.intRangeAtMost(u32, 10000, 30000);
        const steps = 20;
        const step_duration = process_time / steps;

        // Process with progress updates
        var i: u32 = 0;
        while (i < steps) : (i += 1) {
            const progress = ((i + 1) * 100) / steps;
            const bar_width = 20;
            const filled = (progress * bar_width) / 100;

            // Clear line and print progress
            print("\r{s}", .{CLEAR_LINE});
            print("  {s} [", .{spinner_chars[spinner_idx % spinner_chars.len]});

            var j: usize = 0;
            while (j < filled) : (j += 1) {
                print("█", .{});
            }
            while (j < bar_width) : (j += 1) {
                print("░", .{});
            }

            print("] {d: >3}% {s} ({d}/{d})", .{
                progress,
                filename,
                idx + 1,
                filenames.len,
            });

            // Flush output
            std.io.getStdOut().writer().context.sync() catch {};

            // Update spinner
            spinner_idx += 1;

            // Simulate work with variability
            const variation = rng.intRangeAtMost(i32, -50, 50);
            const sleep_ms = @as(u32, @intCast(@max(0, @as(i32, @intCast(step_duration)) + variation)));
            time.sleep(sleep_ms * time.ns_per_ms);
        }

        // Show completed
        print("\r{s}", .{CLEAR_LINE});
        print("  ✓ [████████████████████] 100% {s} ({d}/{d})\n", .{
            filename,
            idx + 1,
            filenames.len,
        });
    }

    // Show cursor
    print("{s}", .{SHOW_CURSOR});
    print("\n✨ All files processed successfully!\n", .{});
}

// Multi-threaded mode (original functionality)
fn runMultiThreaded(filenames: []const []const u8) !void {
    print("🚀 Starting parallel file processing with {d} worker threads...\n\n", .{MAX_WORKERS});

    var prng = std.Random.DefaultPrng.init(@intCast(time.timestamp()));
    var rng = prng.random();

    // Create worker states
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var workers = try allocator.alloc(WorkerState, filenames.len);
    defer allocator.free(workers);

    for (filenames, 0..) |filename, i| {
        // Random processing time between 10-30 seconds
        const process_time = rng.intRangeAtMost(u32, 10000, 30000);
        workers[i] = WorkerState.init(@intCast(i), filename, process_time);
    }

    // Create work queue
    var queue = WorkQueue.init(workers);

    // Start display thread
    display_running.store(true, .release);
    const display_thread = try Thread.spawn(.{}, displayProgress, .{ workers, &queue });

    // Start worker threads (limited to MAX_WORKERS)
    var threads: [MAX_WORKERS]Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try Thread.spawn(.{}, workerThread, .{&queue});
    }

    // Wait for all worker threads to complete
    for (threads) |thread| {
        thread.join();
    }

    // Stop display thread
    display_running.store(false, .release);
    display_thread.join();

    // Clear the display area and show completion message
    var i: usize = 0;
    while (i < MAX_WORKERS + 2) : (i += 1) {
        print("{s}", .{MOVE_UP});
    }
    while (i > 0) : (i -= 1) {
        print("{s}\r\n", .{CLEAR_LINE});
    }

    print("\n✨ All files processed successfully!\n", .{});
}
