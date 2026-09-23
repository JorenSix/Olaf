const std = @import("std");
const Io = std.Io;

const types = @import("../olaf_cli_types.zig");
const olaf_cli_util = @import("../olaf_cli_util.zig");
const olaf_cli_util_audio = @import("../olaf_cli_util_audio.zig");
const olaf_cli_threading = @import("../olaf_cli_threading.zig");

const print = olaf_cli_util.print;

pub const CommandInfo = struct {
    pub const name = "to_raw";
    pub const description = "Converts audio to RAW format (f32le, mono, target_sample_rate) for debugging.\n\tWrites olaf_audio_<name>.raw into the current directory.\n\t-f, --force\t Convert again when the output file already exists.\n\t--threads n\t The number of threads to use.";
    pub const help = "[-f] [--threads n] audio_files...";
    pub const needs_audio_files = true;
    pub const flags = &[_]types.Flag{ .threads, .force };
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
        const output = try std.fmt.allocPrint(arena, "olaf_audio_{s}.raw", .{std.fs.path.stem(input_abs)});
        try jobs.append(arena, .{ .input = audio_file.path, .input_abs = input_abs, .output = output, .col1 = audio_file.path, .col2 = output });
    }

    failures += try olaf_cli_threading.runTranscodeJobs(args.io, allocator, jobs.items, args.threads, args.config.?.target_sample_rate, olaf_cli_util_audio.convertToRaw, args.force);

    if (failures > 0) {
        print("RAW conversion completed with {d} error(s)\n", .{failures});
        return error.ProcessingFailed;
    }
}
