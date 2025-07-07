const std = @import("std");

// You can define your own debug function or import it from another module
const debug = std.debug.print;

/// Runs a command given by `argv`, capturing stdout and stderr output.
/// Returns the process termination status and output as slices.
pub fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8) !struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
} {
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    const cmd_str = try std.mem.join(allocator, " ", argv);
    defer allocator.free(cmd_str);
    debug("Running command: {s}\n", .{cmd_str});

    try child.spawn();

    // Use ArrayList to collect output as it streams in
    var stdout_list = std.ArrayList(u8).init(allocator);
    defer stdout_list.deinit();
    var stderr_list = std.ArrayList(u8).init(allocator);
    defer stderr_list.deinit();

    var stdout_reader = child.stdout.?.reader();
    var stderr_reader = child.stderr.?.reader();

    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;

    // Read both streams until EOF
    var stdout_done = false;
    var stderr_done = false;
    while (!stdout_done or !stderr_done) {
        if (!stdout_done) {
            const n = stdout_reader.read(&stdout_buf) catch |err| return err;
            if (n == 0) {
                stdout_done = true;
            } else {
                //print the output to stdout
                debug("{s}", .{stdout_buf[0..n]}); // Uncomment to print stdout in real-time
                try stdout_list.appendSlice(stdout_buf[0..n]);
            }
        }
        if (!stderr_done) {
            const n = stderr_reader.read(&stderr_buf) catch |err| return err;
            if (n == 0) {
                stderr_done = true;
            } else {
                debug("{s}", .{stderr_buf[0..n]}); // Uncomment to print stdout in real-time
                try stderr_list.appendSlice(stderr_buf[0..n]);
            }
        }
    }

    const term = try child.wait();

    return .{
        .term = term,
        .stdout = try stdout_list.toOwnedSlice(),
        .stderr = try stderr_list.toOwnedSlice(),
    };
}

/// Converts an audio file to raw PCM format (f32le)
/// Returns the path to the output file
pub fn convertToRaw(
    allocator: std.mem.Allocator,
    audio_file: []const u8,
    output_path: []const u8,
    sample_rate: u32,
) !void {
    const sample_rate_str = try std.fmt.allocPrint(allocator, "{d}", .{sample_rate});
    defer allocator.free(sample_rate_str);

    const result = try runCommand(allocator, &.{
        "ffmpeg",    "-hide_banner", "-y",  "-loglevel",     "panic", "-i",    audio_file,
        "-ac",       "1",            "-ar", sample_rate_str, "-f",    "f32le", "-acodec",
        "pcm_f32le", output_path,
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    // Check if the command succeeded
    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                std.debug.print("ffmpeg exited with code: {d}\n", .{code});
                std.debug.print("stderr: {s}\n", .{result.stderr});
                return error.FFmpegFailed;
            }
        },
        else => return error.FFmpegFailed,
    }
}

/// Converts a raw PCM file to WAV format
pub fn convertRawToWav(
    allocator: std.mem.Allocator,
    raw_file: []const u8,
    wav_file: []const u8,
    sample_rate: u32,
) !void {
    const sample_rate_str = try std.fmt.allocPrint(allocator, "{d}", .{sample_rate});
    defer allocator.free(sample_rate_str);

    const result = try runCommand(allocator, &.{
        "ffmpeg", "-hide_banner", "-y",        "-loglevel",     "panic",
        "-ac",    "1",            "-ar",       sample_rate_str, "-f",
        "f32le",  "-acodec",      "pcm_f32le", "-i",            raw_file,
        wav_file,
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    // Check if the command succeeded
    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                std.debug.print("ffmpeg exited with code: {d}\n", .{code});
                std.debug.print("stderr: {s}\n", .{result.stderr});
                return error.FFmpegFailed;
            }
        },
        else => return error.FFmpegFailed,
    }
}

/// Converts any audio file to WAV format
pub fn convertToWav(
    allocator: std.mem.Allocator,
    audio_file: []const u8,
    wav_file: []const u8,
    sample_rate: u32,
) !void {
    const sample_rate_str = try std.fmt.allocPrint(allocator, "{d}", .{sample_rate});
    defer allocator.free(sample_rate_str);

    const result = try runCommand(allocator, &.{
        "ffmpeg", "-hide_banner", "-y",  "-loglevel",     "panic",  "-i", audio_file,
        "-ac",    "1",            "-ar", sample_rate_str, wav_file,
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    // Check if the command succeeded
    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                std.debug.print("ffmpeg exited with code: {d}\n", .{code});
                std.debug.print("stderr: {s}\n", .{result.stderr});
                return error.FFmpegFailed;
            }
        },
        else => return error.FFmpegFailed,
    }
}

/// Gets the duration of an audio file in seconds
pub fn getAudioDuration(allocator: std.mem.Allocator, audio_file: []const u8) !f32 {
    const result = try runCommand(allocator, &.{
        "ffprobe", "-i",    audio_file, "-show_entries", "format=duration",
        "-v",      "quiet", "-of",      "csv=p=0",
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const trimmed = std.mem.trim(u8, result.stdout, " \t\n\r");
    return try std.fmt.parseFloat(f32, trimmed);
}

/// Audio processing options
pub const AudioOptions = struct {
    sample_rate: u32 = 16000,
    channels: u32 = 1,
    format: []const u8 = "f32le",
    codec: []const u8 = "pcm_f32le",
};

/// Converts audio with custom options
pub fn convertAudioWithOptions(
    allocator: std.mem.Allocator,
    input_file: []const u8,
    output_file: []const u8,
    options: AudioOptions,
) !void {
    const sample_rate_str = try std.fmt.allocPrint(allocator, "{d}", .{options.sample_rate});
    defer allocator.free(sample_rate_str);

    const channels_str = try std.fmt.allocPrint(allocator, "{d}", .{options.channels});
    defer allocator.free(channels_str);

    const result = try runCommand(allocator, &.{
        "ffmpeg",      "-hide_banner", "-y",  "-loglevel",     "panic", "-i",           input_file,
        "-ac",         channels_str,   "-ar", sample_rate_str, "-f",    options.format, "-acodec",
        options.codec, output_file,
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    // Check if the command succeeded
    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                std.debug.print("ffmpeg exited with code: {d}\n", .{code});
                std.debug.print("stderr: {s}\n", .{result.stderr});
                return error.FFmpegFailed;
            }
        },
        else => return error.FFmpegFailed,
    }
}

// Example usage
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Example: Convert MP3 to WAV
    try convertToWav(allocator, "input.mp3", "output.wav", 16000);

    // Example: Convert MP3 to raw PCM
    try convertToRaw(allocator, "input.mp3", "output.raw", 16000);

    // Example: Convert raw PCM to WAV
    try convertRawToWav(allocator, "output.raw", "output2.wav", 16000);

    // Example: Get audio duration
    const duration = try getAudioDuration(allocator, "input.mp3");
    std.debug.print("Duration: {d:.2} seconds\n", .{duration});

    // Example: Convert with custom options
    const options = AudioOptions{
        .sample_rate = 44100,
        .channels = 2,
        .format = "f32le",
        .codec = "pcm_f32le",
    };
    try convertAudioWithOptions(allocator, "input.mp3", "output_custom.raw", options);
}
