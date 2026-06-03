const std = @import("std");
const Io = std.Io;

const types = @import("../olaf_cli_types.zig");
const olaf_cli_util = @import("../olaf_cli_util.zig");
const olaf_cli_util_audio = @import("../olaf_cli_util_audio.zig");
const olaf_cli_threading = @import("../olaf_cli_threading.zig");

const print = olaf_cli_util.print;

pub const CommandInfo = struct {
    pub const name = "to_raw";
    pub const description = "Converts audio to RAW format (f32le, mono, 16kHz) for debugging.\n\t--threads n\t The number of threads to use.";
    pub const help = "[--threads n] audio_files...";
    pub const needs_audio_files = true;
};

const RawCtx = struct {
    io: Io,
    sample_rate: u32,
    output_mutex: *Io.Mutex,
};

// Helper function to generate output filename for raw conversion
fn generateRawFilename(io: Io, allocator: std.mem.Allocator, audio_path: []const u8) !struct { basename: []u8, raw_filename: []u8 } {
    // Dupe a non-sentinel slice: realPathFileAlloc returns a [:0]u8 of n+1 bytes,
    // which would mismatch a later free of the n-length basename slice.
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_len = try Io.Dir.cwd().realPathFile(io, audio_path, &abs_buf);
    const full_basename = try allocator.dupe(u8, abs_buf[0..abs_len]);

    const ext_start = std.mem.lastIndexOf(u8, full_basename, ".");
    const basename = if (ext_start) |idx| full_basename[0..idx] else full_basename;

    // Extract just the filename without directory path for the output
    const filename_start = std.mem.lastIndexOf(u8, basename, "/") orelse std.mem.lastIndexOf(u8, basename, "\\");
    const just_basename = if (filename_start) |idx| basename[idx + 1 ..] else basename;

    const raw_filename = try std.fmt.allocPrint(allocator, "olaf_audio_{s}.raw", .{just_basename});

    return .{ .basename = full_basename, .raw_filename = raw_filename };
}

fn rawWorker(ctx: RawCtx, audio_file: olaf_cli_util.AudioFileWithId, index: usize, total: usize, allocator: std.mem.Allocator) !void {
    const names = try generateRawFilename(ctx.io, allocator, audio_file.path);
    defer {
        allocator.free(names.basename);
        allocator.free(names.raw_filename);
    }

    try olaf_cli_threading.transcodeAndReport(
        ctx.io,
        allocator,
        olaf_cli_util_audio.convertToRaw,
        audio_file.path,
        names.raw_filename,
        ctx.sample_rate,
        index,
        total,
        audio_file.path,
        names.raw_filename,
        ctx.output_mutex,
    );
}

pub fn execute(allocator: std.mem.Allocator, args: *types.Args) !void {
    var output_mutex: Io.Mutex = .init;
    const ctx = RawCtx{ .io = args.io, .sample_rate = args.config.?.target_sample_rate, .output_mutex = &output_mutex };

    const error_count = try olaf_cli_threading.forEachParallel(
        olaf_cli_util.AudioFileWithId,
        RawCtx,
        args.io,
        allocator,
        args.audio_files.items,
        args.threads,
        ctx,
        rawWorker,
    );

    if (error_count > 0) {
        print("RAW conversion completed with {d} error(s)\n", .{error_count});
        return error.ProcessingFailed;
    }
}
