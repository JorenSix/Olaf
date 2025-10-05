const std = @import("std");
const testing = std.testing;

// You can define your own debug function or import it from another module
const debug = std.log.scoped(.olaf_wrapper_util_audio).debug;
const info = std.log.scoped(.olaf_wrapper_util_audio).info;

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

    // Log the command being run (with proper quoting for clarity)
    var command_str = std.ArrayList(u8).init(allocator);
    defer command_str.deinit();

    try command_str.appendSlice("Running command:");

    for (argv) |arg| {
        // Quote arguments that contain spaces or special characters
        if (std.mem.indexOfAny(u8, arg, " &'\"()[]{}$") != null) {
            try command_str.writer().print(" '{s}'", .{arg});
        } else {
            try command_str.writer().print(" {s}", .{arg});
        }
    }

    debug("{s}", .{command_str.items});

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

/// Audio processing options
pub const AudioOptions = struct {
    // Output options
    sample_rate: u32 = 16000,
    output_channels: u32 = 1,
    output_format: []const u8 = "f32le",
    output_codec: []const u8 = "pcm_f32le",

    // Input options (optional)
    input_format: ?[]const u8 = null,
    input_codec: ?[]const u8 = null,
    input_channels: ?u32 = null,

    // Time options
    start: ?f32 = null, // Start time in seconds (optional)
    duration: ?f32 = null, // Duration in seconds (optional)
};

/// Converts an audio file to raw PCM format (f32le)
/// Returns the path to the output file
pub fn convertToRaw(
    allocator: std.mem.Allocator,
    audio_file: []const u8,
    output_path: []const u8,
    sample_rate: u32,
) !void {
    const options = AudioOptions{
        .sample_rate = sample_rate,
        .output_channels = 1,
        .output_format = "f32le",
        .output_codec = "pcm_f32le",
    };
    try convertAudioWithOptions(allocator, audio_file, output_path, options);
}

/// Converts a raw PCM file to WAV format
pub fn convertRawToWav(
    allocator: std.mem.Allocator,
    raw_file: []const u8,
    wav_file: []const u8,
    sample_rate: u32,
) !void {
    const options = AudioOptions{
        .sample_rate = sample_rate,
        .output_channels = 1,
        .output_format = "wav",
        .output_codec = "pcm_s16le",
        // Input format for raw PCM
        .input_format = "f32le",
        .input_codec = "pcm_f32le",
        .input_channels = 1,
    };
    try convertAudioWithOptions(allocator, raw_file, wav_file, options);
}

/// Converts any audio file to WAV format
pub fn convertToWav(
    allocator: std.mem.Allocator,
    audio_file: []const u8,
    wav_file: []const u8,
    sample_rate: u32,
) !void {
    const options = AudioOptions{
        .sample_rate = sample_rate,
        .output_channels = 1,
        .output_format = "wav",
        .output_codec = "pcm_s16le", // Standard WAV codec
    };
    try convertAudioWithOptions(allocator, audio_file, wav_file, options);
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

/// Converts audio with custom options
pub fn convertAudioWithOptions(
    allocator: std.mem.Allocator,
    input_file: []const u8,
    output_file: []const u8,
    options: AudioOptions,
) !void {
    var args = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();

    // Keep track of allocated strings to free them later
    var allocated_strings = std.ArrayList([]u8).init(allocator);
    defer {
        for (allocated_strings.items) |str| {
            allocator.free(str);
        }
        allocated_strings.deinit();
    }

    // Base ffmpeg args
    try args.appendSlice(&.{ "ffmpeg", "-hide_banner", "-y", "-loglevel", "panic" });

    // Add input format options if specified (before input file)
    if (options.input_format) |format| {
        try args.appendSlice(&.{ "-f", format });
    }

    if (options.input_codec) |codec| {
        try args.appendSlice(&.{ "-acodec", codec });
    }

    if (options.input_channels) |channels| {
        const channels_str = try std.fmt.allocPrint(allocator, "{d}", .{channels});
        try allocated_strings.append(channels_str);
        try args.appendSlice(&.{ "-ac", channels_str });
    }

    // Add start time if specified (before input file)
    if (options.start) |start| {
        const start_str = try std.fmt.allocPrint(allocator, "{d:.3}", .{start});
        try allocated_strings.append(start_str);
        try args.appendSlice(&.{ "-ss", start_str });
    }

    // Sample rate for input (needed for raw formats)
    if (options.input_format) |format| {
        if (std.mem.eql(u8, format, "f32le") or std.mem.eql(u8, format, "s16le") or std.mem.eql(u8, format, "s32le")) {
            const sample_rate_str = try std.fmt.allocPrint(allocator, "{d}", .{options.sample_rate});
            try allocated_strings.append(sample_rate_str);
            try args.appendSlice(&.{ "-ar", sample_rate_str });
        }
    }

    // Input file
    try args.appendSlice(&.{ "-i", input_file });

    // Add duration if specified (after input file)
    if (options.duration) |duration| {
        const duration_str = try std.fmt.allocPrint(allocator, "{d:.3}", .{duration});
        try allocated_strings.append(duration_str);
        try args.appendSlice(&.{ "-t", duration_str });
    }

    // Output audio settings
    const output_channels_str = try std.fmt.allocPrint(allocator, "{d}", .{options.output_channels});
    try allocated_strings.append(output_channels_str);

    const sample_rate_str = try std.fmt.allocPrint(allocator, "{d}", .{options.sample_rate});
    try allocated_strings.append(sample_rate_str);

    try args.appendSlice(&.{
        "-ac",       output_channels_str,
        "-ar",       sample_rate_str,
        "-f",        options.output_format,
        "-acodec",   options.output_codec,
        output_file,
    });

    const result = try runCommand(allocator, args.items);
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

// Helper function to clean up test files
fn cleanupTestFiles(files: []const []const u8) void {
    for (files) |file| {
        std.fs.cwd().deleteFile(file) catch {
            // Ignore errors, file might not exist
        };
    }
}

// Helper function to check if test file exists
fn checkTestFileExists() !void {
    const file = std.fs.cwd().openFile("input.mp3", .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("\nSkipping tests: 'input.mp3' not found in current directory.\n", .{});
            std.debug.print("Please provide a test audio file named 'input.mp3' (ideally ~10 seconds long) to run tests.\n\n", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
    file.close();
}

// Test: Original file duration
test "audio duration remains consistent after conversion" {
    try checkTestFileExists();

    const allocator = testing.allocator;

    const test_files = [_][]const u8{
        "test_output.wav",
        "test_output.raw",
    };
    defer cleanupTestFiles(&test_files);

    // Get original duration
    const original_duration = try getAudioDuration(allocator, "input.mp3");

    // Convert to WAV
    try convertToWav(allocator, "input.mp3", "test_output.wav", 16000);
    const wav_duration = try getAudioDuration(allocator, "test_output.wav");

    // Duration should be within 0.1 seconds
    try testing.expect(@abs(wav_duration - original_duration) < 0.1);
}

// Test: MP3 to RAW to WAV conversion chain
test "conversion chain preserves duration" {
    try checkTestFileExists();

    const allocator = testing.allocator;

    const test_files = [_][]const u8{
        "test_chain.raw",
        "test_chain.wav",
    };
    defer cleanupTestFiles(&test_files);

    const original_duration = try getAudioDuration(allocator, "input.mp3");

    // Convert MP3 -> RAW -> WAV
    try convertToRaw(allocator, "input.mp3", "test_chain.raw", 16000);
    try convertRawToWav(allocator, "test_chain.raw", "test_chain.wav", 16000);

    const final_duration = try getAudioDuration(allocator, "test_chain.wav");

    // Duration should be preserved
    try testing.expect(@abs(final_duration - original_duration) < 0.1);
}

// Test: Extract specific time segment
test "extract audio segment with correct duration" {
    try checkTestFileExists();

    const allocator = testing.allocator;

    const test_files = [_][]const u8{
        "test_clip.raw",
        "test_clip.wav",
    };
    defer cleanupTestFiles(&test_files);

    // Extract 3 seconds starting at 1 second
    const clip_options = AudioOptions{
        .sample_rate = 16000,
        .output_channels = 1,
        .output_format = "f32le",
        .output_codec = "pcm_f32le",
        .start = 1.0,
        .duration = 3.0,
    };

    try convertAudioWithOptions(allocator, "input.mp3", "test_clip.raw", clip_options);
    try convertRawToWav(allocator, "test_clip.raw", "test_clip.wav", 16000);

    const clip_duration = try getAudioDuration(allocator, "test_clip.wav");

    // Clip should be 3 seconds (within tolerance)
    try testing.expect(@abs(clip_duration - 3.0) < 0.1);
}

// Test: Multiple sequential clips
test "sequential clips have correct durations" {
    try checkTestFileExists();

    const allocator = testing.allocator;

    const test_files = [_][]const u8{
        "test_seq1.wav",
        "test_seq2.wav",
        "test_seq3.wav",
    };
    defer cleanupTestFiles(&test_files);

    // Create three 2-second clips
    const clip_opts = [3]AudioOptions{
        .{
            .sample_rate = 16000,
            .output_channels = 1,
            .output_format = "wav",
            .output_codec = "pcm_s16le",
            .start = 0.0,
            .duration = 2.0,
        },
        .{
            .sample_rate = 16000,
            .output_channels = 1,
            .output_format = "wav",
            .output_codec = "pcm_s16le",
            .start = 2.0,
            .duration = 2.0,
        },
        .{
            .sample_rate = 16000,
            .output_channels = 1,
            .output_format = "wav",
            .output_codec = "pcm_s16le",
            .start = 4.0,
            .duration = 2.0,
        },
    };

    try convertAudioWithOptions(allocator, "input.mp3", "test_seq1.wav", clip_opts[0]);
    try convertAudioWithOptions(allocator, "input.mp3", "test_seq2.wav", clip_opts[1]);
    try convertAudioWithOptions(allocator, "input.mp3", "test_seq3.wav", clip_opts[2]);

    const dur1 = try getAudioDuration(allocator, "test_seq1.wav");
    const dur2 = try getAudioDuration(allocator, "test_seq2.wav");
    const dur3 = try getAudioDuration(allocator, "test_seq3.wav");

    // Each clip should be 2 seconds
    try testing.expect(@abs(dur1 - 2.0) < 0.1);
    try testing.expect(@abs(dur2 - 2.0) < 0.1);
    try testing.expect(@abs(dur3 - 2.0) < 0.1);

    // Total should be 6 seconds
    const total = dur1 + dur2 + dur3;
    try testing.expect(@abs(total - 6.0) < 0.1);
}

// Test: Round-trip conversion
test "round-trip conversion preserves duration" {
    try checkTestFileExists();

    const allocator = testing.allocator;

    const test_files = [_][]const u8{
        "test_rt_input.wav",
        "test_rt.raw",
        "test_rt_output.wav",
    };
    defer cleanupTestFiles(&test_files);

    // First create a WAV file
    try convertToWav(allocator, "input.mp3", "test_rt_input.wav", 16000);
    const original_duration = try getAudioDuration(allocator, "test_rt_input.wav");

    // WAV -> RAW
    const wav_to_raw_options = AudioOptions{
        .sample_rate = 16000,
        .output_channels = 1,
        .output_format = "f32le",
        .output_codec = "pcm_f32le",
        .input_format = "wav",
    };
    try convertAudioWithOptions(allocator, "test_rt_input.wav", "test_rt.raw", wav_to_raw_options);

    // RAW -> WAV
    try convertRawToWav(allocator, "test_rt.raw", "test_rt_output.wav", 16000);

    const final_duration = try getAudioDuration(allocator, "test_rt_output.wav");

    // Duration should be preserved
    try testing.expect(@abs(final_duration - original_duration) < 0.05);
}

// Test: Input format options
test "raw input format options work correctly" {
    try checkTestFileExists();

    const allocator = testing.allocator;

    const test_files = [_][]const u8{
        "test_stereo.raw",
        "test_mono.wav",
    };
    defer cleanupTestFiles(&test_files);

    // Create a stereo raw file
    const stereo_options = AudioOptions{
        .sample_rate = 48000,
        .output_channels = 2,
        .output_format = "f32le",
        .output_codec = "pcm_f32le",
    };
    try convertAudioWithOptions(allocator, "input.mp3", "test_stereo.raw", stereo_options);

    // Convert stereo raw to mono WAV
    const convert_options = AudioOptions{
        .sample_rate = 48000,
        .output_channels = 1,
        .output_format = "wav",
        .output_codec = "pcm_s16le",
        .input_format = "f32le",
        .input_codec = "pcm_f32le",
        .input_channels = 2,
    };
    try convertAudioWithOptions(allocator, "test_stereo.raw", "test_mono.wav", convert_options);

    // Check that output exists and has valid duration
    const duration = try getAudioDuration(allocator, "test_mono.wav");
    try testing.expect(duration > 0);
}

// Test: Handle file paths with spaces and special characters
test "handles file paths with spaces and special characters" {
    try checkTestFileExists();

    const allocator = testing.allocator;

    const test_files = [_][]const u8{
        "test file with spaces.wav",
        "test&file&with&ampersands.wav",
        "test'file'with'quotes.wav",
        "test (file) with parens.wav",
    };
    defer cleanupTestFiles(&test_files);

    // Test 1: File with spaces
    try convertToWav(allocator, "input.mp3", "test file with spaces.wav", 16000);
    const duration1 = try getAudioDuration(allocator, "test file with spaces.wav");
    try testing.expect(duration1 > 0);

    // Test 2: File with ampersands
    try convertToWav(allocator, "input.mp3", "test&file&with&ampersands.wav", 16000);
    const duration2 = try getAudioDuration(allocator, "test&file&with&ampersands.wav");
    try testing.expect(duration2 > 0);

    // Test 3: File with single quotes
    try convertToWav(allocator, "input.mp3", "test'file'with'quotes.wav", 16000);
    const duration3 = try getAudioDuration(allocator, "test'file'with'quotes.wav");
    try testing.expect(duration3 > 0);

    // Test 4: File with parentheses
    try convertToWav(allocator, "input.mp3", "test (file) with parens.wav", 16000);
    const duration4 = try getAudioDuration(allocator, "test (file) with parens.wav");
    try testing.expect(duration4 > 0);
}

// Example usage (not run during tests)
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
    info("Duration: {d:.2} seconds", .{duration});

    // Example: Handle files with special characters
    info("\nTesting files with special characters:", .{});

    // Create a file with spaces in the name
    try convertToWav(allocator, "input.mp3", "output with spaces.wav", 16000);
    const duration_spaces = try getAudioDuration(allocator, "output with spaces.wav");
    info("File with spaces duration: {d:.2} seconds", .{duration_spaces});

    // Create a file with ampersands
    try convertToWav(allocator, "input.mp3", "output&with&ampersands.wav", 16000);
    const duration_amp = try getAudioDuration(allocator, "output&with&ampersands.wav");
    info("File with ampersands duration: {d:.2} seconds", .{duration_amp});

    info("All conversions completed successfully!", .{});
    info("Run 'zig test olaf_wrapper_util_audio.zig' to run the test suite", .{});
}
