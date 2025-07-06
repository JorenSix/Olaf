const std = @import("std");
const print = std.debug.print;
const Thread = std.Thread;
const time = std.time;
const Atomic = std.atomic.Value;
const Random = std.Random;

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
fn displayProgress(workers: []WorkerState) void {
    const spinner_chars = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
    var spinner_idx: usize = 0;

    // Hide cursor for cleaner display
    print("{s}", .{HIDE_CURSOR});

    // Initial setup - print empty lines for each worker
    for (workers) |_| {
        print("\n", .{});
    }

    while (display_running.load(.acquire)) {
        // Move cursor up to start of worker list
        for (workers) |_| {
            print("{s}", .{MOVE_UP});
        }

        // Display each worker's status
        for (workers) |*worker| {
            const status = worker.status.load(.acquire);
            const progress = worker.progress.load(.acquire);

            print("{s}\r", .{CLEAR_LINE});

            switch (status) {
                .waiting => {
                    print("  {s} {s}: Waiting...", .{ spinner_chars[spinner_idx % spinner_chars.len], worker.filename });
                },
                .processing => {
                    const bar_width = 20;
                    const filled = (progress * bar_width) / 100;

                    print("  {s} {s}: [", .{ spinner_chars[spinner_idx % spinner_chars.len], worker.filename });

                    // Print progress bar
                    var i: usize = 0;
                    while (i < filled) : (i += 1) {
                        print("█", .{});
                    }
                    while (i < bar_width) : (i += 1) {
                        print("░", .{});
                    }

                    print("] {d}%", .{progress});
                },
                .completed => {
                    print("  ✓ {s}: Completed", .{worker.filename});
                },
                .failed => {
                    print("  ✗ {s}: Failed", .{worker.filename});
                },
            }

            print("\n", .{});
        }

        // Update spinner
        spinner_idx += 1;

        // Small delay for smooth animation
        time.sleep(80 * time.ns_per_ms);
    }

    // Show cursor again
    print("{s}", .{SHOW_CURSOR});
}

// Worker function that simulates file processing
fn processFile(worker: *WorkerState) void {
    var prng = std.Random.DefaultPrng.init(@intCast(time.timestamp()));
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

pub fn main() !void {
    print("🚀 Starting parallel file processing...\n\n", .{});

    // List of files to process
    const filenames = [_][]const u8{
        "data_export_2024.csv",
        "user_analytics.json",
        "system_logs.txt",
        "backup_archive.tar.gz",
        "config_settings.xml",
        "report_summary.pdf",
    };

    var prng = std.Random.DefaultPrng.init(@intCast(time.timestamp()));
    var rng = prng.random();

    // Create worker states
    var workers: [filenames.len]WorkerState = undefined;
    for (filenames, 0..) |filename, i| {
        // Random processing time between 10-30 seconds
        const process_time = rng.intRangeAtMost(u32, 10000, 30000);
        workers[i] = WorkerState.init(@intCast(i), filename, process_time);
    }

    // Start display thread
    display_running.store(true, .release);
    const display_thread = try Thread.spawn(.{}, displayProgress, .{&workers});

    // Start worker threads
    var threads: [filenames.len]Thread = undefined;
    for (&workers, 0..) |*worker, i| {
        threads[i] = try Thread.spawn(.{}, processFile, .{worker});
    }

    // Wait for all workers to complete
    for (threads) |thread| {
        thread.join();
    }

    // Stop display thread
    display_running.store(false, .release);
    display_thread.join();

    // Final summary
    print("\n✨ All files processed successfully!\n", .{});

    // Print processing times
    print("\nProcessing Summary:\n", .{});
    for (workers) |worker| {
        const duration_s = @as(f64, @floatFromInt(worker.total_ms)) / 1000.0;
        print("  • {s}: {d:.1}s\n", .{ worker.filename, duration_s });
    }
}
