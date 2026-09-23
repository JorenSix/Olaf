const std = @import("std");
const Io = std.Io;

const types = @import("../olaf_cli_types.zig");
const olaf_cli_util = @import("../olaf_cli_util.zig");
const olaf_cli_util_audio = @import("../olaf_cli_util_audio.zig");
const olaf_cli_threading = @import("../olaf_cli_threading.zig");

const print = olaf_cli_util.print;

pub const CommandInfo = struct {
    pub const name = "to_wav";
    pub const description = "Converts audio to single channel wav, written next to the input as <name>.wav.\n\t--threads n\t The number of threads to use.";
    pub const help = "[--threads n] audio_files...";
    pub const needs_audio_files = true;
};

pub fn execute(allocator: std.mem.Allocator, args: *types.Args) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var failures: usize = 0;
    var jobs: std.ArrayList(olaf_cli_threading.TranscodeJob) = .empty;
    for (args.audio_files.items) |audio_file| {
        const input_abs = Io.Dir.cwd().realPathFileAlloc(args.io, audio_file.path, arena) catch |err| {
            std.log.err("{s}: {}", .{ audio_file.path, err });
            failures += 1;
            continue;
        };
        const dir = std.fs.path.dirname(input_abs) orelse ".";
        const without_ext = try std.fs.path.join(arena, &.{ dir, std.fs.path.stem(input_abs) });
        const output = try std.fmt.allocPrint(arena, "{s}.wav", .{without_ext});
        try jobs.append(arena, .{ .input = audio_file.path, .input_abs = input_abs, .output = output, .col1 = without_ext, .col2 = output });
    }

    failures += try olaf_cli_threading.runTranscodeJobs(args.io, allocator, jobs.items, args.threads, args.config.?.target_sample_rate, olaf_cli_util_audio.convertToWav);

    if (failures > 0) {
        print("WAV conversion completed with {d} error(s)\n", .{failures});
        return error.ProcessingFailed;
    }
}
