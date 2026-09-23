const std = @import("std");
const Io = std.Io;

const debug = std.log.scoped(.olaf_wrapper_util_audio).debug;
const log_err = std.log.scoped(.olaf_wrapper_util_audio).err;

/// Runs a command given by `argv`, capturing stdout and stderr output.
/// Returns the process termination status and output as slices.
/// Caller owns the returned stdout/stderr memory.
fn runCommand(allocator: std.mem.Allocator, io: Io, argv: []const []const u8) !std.process.RunResult {
    return std.process.run(allocator, io, .{ .argv = argv });
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
    io: Io,
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
    try convertAudioWithOptions(allocator, io, audio_file, output_path, options);
}

/// Converts a raw PCM file to WAV format
pub fn convertRawToWav(
    allocator: std.mem.Allocator,
    io: Io,
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
    try convertAudioWithOptions(allocator, io, raw_file, wav_file, options);
}

/// Converts any audio file to WAV format
pub fn convertToWav(
    allocator: std.mem.Allocator,
    io: Io,
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
    try convertAudioWithOptions(allocator, io, audio_file, wav_file, options);
}

/// Gets the duration of an audio file in seconds
pub fn getAudioDuration(allocator: std.mem.Allocator, io: Io, audio_file: []const u8) !f32 {
    const result = try runCommand(allocator, io, &.{
        "ffprobe", "-i",    audio_file, "-show_entries", "format=duration",
        "-v",      "quiet", "-of",      "csv=p=0",
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    // ffprobe fails on unreadable input and prints "N/A" for streams without
    // a known duration; either way there is nothing to fragment.
    const trimmed = std.mem.trim(u8, result.stdout, " \t\n\r");
    const ok = result.term == .exited and result.term.exited == 0;
    const duration = if (ok) std.fmt.parseFloat(f32, trimmed) catch null else null;
    return duration orelse {
        log_err("could not read the duration of '{s}' (ffprobe: {s})", .{ audio_file, if (trimmed.len > 0) trimmed else "no output" });
        return error.DurationUnavailable;
    };
}

/// Converts audio with custom options
pub fn convertAudioWithOptions(
    allocator: std.mem.Allocator,
    io: Io,
    input_file: []const u8,
    output_file: []const u8,
    options: AudioOptions,
) !void {
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);

    // Keep track of allocated strings to free them later
    var allocated_strings: std.ArrayList([]u8) = .empty;
    defer {
        for (allocated_strings.items) |str| {
            allocator.free(str);
        }
        allocated_strings.deinit(allocator);
    }

    // Base ffmpeg args
    try args.appendSlice(allocator, &.{ "ffmpeg", "-hide_banner", "-y", "-loglevel", "panic" });

    // Add input format options if specified (before input file)
    if (options.input_format) |format| {
        try args.appendSlice(allocator, &.{ "-f", format });
    }

    if (options.input_codec) |codec| {
        try args.appendSlice(allocator, &.{ "-acodec", codec });
    }

    if (options.input_channels) |channels| {
        const channels_str = try std.fmt.allocPrint(allocator, "{d}", .{channels});
        try allocated_strings.append(allocator, channels_str);
        try args.appendSlice(allocator, &.{ "-ac", channels_str });
    }

    // Add start time if specified (before input file)
    if (options.start) |start| {
        const start_str = try std.fmt.allocPrint(allocator, "{d:.3}", .{start});
        try allocated_strings.append(allocator, start_str);
        try args.appendSlice(allocator, &.{ "-ss", start_str });
    }

    // Sample rate for input (needed for raw formats)
    if (options.input_format) |format| {
        if (std.mem.eql(u8, format, "f32le") or std.mem.eql(u8, format, "s16le") or std.mem.eql(u8, format, "s32le")) {
            const sample_rate_str = try std.fmt.allocPrint(allocator, "{d}", .{options.sample_rate});
            try allocated_strings.append(allocator, sample_rate_str);
            try args.appendSlice(allocator, &.{ "-ar", sample_rate_str });
        }
    }

    // Input file
    try args.appendSlice(allocator, &.{ "-i", input_file });

    // Add duration if specified (after input file)
    if (options.duration) |duration| {
        const duration_str = try std.fmt.allocPrint(allocator, "{d:.3}", .{duration});
        try allocated_strings.append(allocator, duration_str);
        try args.appendSlice(allocator, &.{ "-t", duration_str });
    }

    // Output audio settings
    const output_channels_str = try std.fmt.allocPrint(allocator, "{d}", .{options.output_channels});
    try allocated_strings.append(allocator, output_channels_str);

    const sample_rate_str = try std.fmt.allocPrint(allocator, "{d}", .{options.sample_rate});
    try allocated_strings.append(allocator, sample_rate_str);

    try args.appendSlice(allocator, &.{
        "-ac",       output_channels_str,
        "-ar",       sample_rate_str,
        "-f",        options.output_format,
        "-acodec",   options.output_codec,
        output_file,
    });

    const result = try runCommand(allocator, io, args.items);
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    // Check if the command succeeded
    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                log_err("ffmpeg exited with code {d} for '{s}': {s}", .{ code, input_file, result.stderr });
                return error.FFmpegFailed;
            }
        },
        else => {
            log_err("ffmpeg terminated abnormally for '{s}': {s}", .{ input_file, result.stderr });
            return error.FFmpegFailed;
        },
    }
}
