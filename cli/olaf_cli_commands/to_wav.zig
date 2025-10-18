const std = @import("std");
const Thread = std.Thread;
const Mutex = Thread.Mutex;
const WaitGroup = Thread.WaitGroup;
const fs = std.fs;

const types = @import("../olaf_wrapper_types.zig");
const olaf_wrapper_config = @import("../olaf_wrapper_config.zig");
const olaf_wrapper_util = @import("../olaf_wrapper_util.zig");
const olaf_wrapper_util_audio = @import("../olaf_wrapper_util_audio.zig");

const debug = std.log.scoped(.olaf_wrapper_to_wav).debug;

fn print(comptime fmt: []const u8, args: anytype) void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    _ = stdout.print(fmt, args) catch {};
    _ = stdout.flush() catch {};
}

pub const CommandInfo = struct {
    pub const name = "to_wav";
    pub const description = "Converts audio from to single channel wav.\n\t--threads n\t The number of threads to use.";
    pub const help = "[--threads n] audio_files...";
    pub const needs_audio_files = true;
};

// Worker task for WAV conversion
const WavConversionTask = struct {
    allocator: std.mem.Allocator,
    audio_file: olaf_wrapper_util.AudioFileWithId,
    config: *const olaf_wrapper_config.Config,
    index: usize,
    total: usize,
    error_mutex: *Mutex,
    error_list: *std.ArrayList([]const u8),
    output_mutex: *Mutex,
};

// Helper function to generate output filename for wav conversion
fn generateWavFilename(allocator: std.mem.Allocator, audio_path: []const u8) !struct { basename: []u8, wav_filename: []u8 } {
    const full_basename = try fs.cwd().realpathAlloc(allocator, audio_path);

    const ext_start = std.mem.lastIndexOf(u8, full_basename, ".");
    const basename = if (ext_start) |idx| full_basename[0..idx] else full_basename;

    const wav_filename = try std.fmt.allocPrint(allocator, "{s}.wav", .{basename});

    return .{ .basename = full_basename, .wav_filename = wav_filename };
}

fn processWavConversionThreaded(task: WavConversionTask) void {
    const names = generateWavFilename(task.allocator, task.audio_file.path) catch |gen_err| {
        task.error_mutex.lock();
        defer task.error_mutex.unlock();
        const err_msg = std.fmt.allocPrint(task.allocator, "Failed to generate filename for {s}: {}", .{ task.audio_file.path, gen_err }) catch "Out of memory";
        task.error_list.append(task.allocator, err_msg) catch {};
        std.log.err("{s}", .{err_msg});
        return;
    };
    defer {
        task.allocator.free(names.basename);
        task.allocator.free(names.wav_filename);
    }

    // Check if file already exists
    if (fs.cwd().statFile(names.wav_filename)) |_| {
        debug("Wav file already exists: {s}, skipping", .{names.wav_filename});
    } else |_| {
        olaf_wrapper_util_audio.convertToWav(
            task.allocator,
            task.audio_file.path,
            names.wav_filename,
            task.config.target_sample_rate,
        ) catch |conv_err| {
            task.error_mutex.lock();
            defer task.error_mutex.unlock();
            const err_msg = std.fmt.allocPrint(task.allocator, "Failed to convert {s}: {}", .{ task.audio_file.path, conv_err }) catch "Out of memory";
            task.error_list.append(task.allocator, err_msg) catch {};
            std.log.err("{s}", .{err_msg});
            return;
        };
    }

    // Thread-safe output
    task.output_mutex.lock();
    defer task.output_mutex.unlock();
    print("{d}/{d},{s},{s}\n", .{ task.index + 1, task.total, names.basename, names.wav_filename });
}

pub fn execute(allocator: std.mem.Allocator, args: *types.Args) !void {
    const num_threads = @min(args.threads, args.audio_files.items.len);

    if (num_threads <= 1) {
        // Single-threaded execution (original behavior)
        for (args.audio_files.items, 0..) |audio_file_with_id, i| {
            const names = try generateWavFilename(allocator, audio_file_with_id.path);
            defer {
                debug("Defer basename and wav_filename cleanup", .{});
                allocator.free(names.basename);
                allocator.free(names.wav_filename);
            }

            // Check if file already exists
            if (fs.cwd().statFile(names.wav_filename)) |_| {
                debug("Wav file already exists: {s}, skipping", .{names.wav_filename});
            } else |_| {
                try olaf_wrapper_util_audio.convertToWav(allocator, audio_file_with_id.path, names.wav_filename, args.config.?.target_sample_rate);
            }

            print("{d}/{d},{s},{s}\n", .{ i + 1, args.audio_files.items.len, names.basename, names.wav_filename });
        }
    } else {
        // Multi-threaded execution
        debug("Converting {d} audio files to WAV with {d} threads", .{ args.audio_files.items.len, num_threads });

        var pool: Thread.Pool = undefined;
        try pool.init(.{ .allocator = allocator, .n_jobs = num_threads });
        defer pool.deinit();

        var wait_group: WaitGroup = undefined;
        wait_group.reset();

        var error_mutex = Mutex{};
        var output_mutex = Mutex{};
        var error_list = std.ArrayList([]const u8){};
        defer {
            for (error_list.items) |err_msg| {
                allocator.free(err_msg);
            }
            error_list.deinit(allocator);
        }

        for (args.audio_files.items, 0..) |audio_file_with_id, i| {
            const task = WavConversionTask{
                .allocator = allocator,
                .audio_file = audio_file_with_id,
                .config = args.config.?,
                .index = i,
                .total = args.audio_files.items.len,
                .error_mutex = &error_mutex,
                .error_list = &error_list,
                .output_mutex = &output_mutex,
            };

            pool.spawnWg(&wait_group, processWavConversionThreaded, .{task});
        }

        // Wait for all tasks to complete
        pool.waitAndWork(&wait_group);

        // Check for errors
        if (error_list.items.len > 0) {
            print("WAV conversion completed with {d} error(s)\n", .{error_list.items.len});
            return error.ProcessingFailed;
        }
    }
}

