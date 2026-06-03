const std = @import("std");
const olaf_cli_bridge = @import("../olaf_cli_bridge.zig");
const olaf_cli_util = @import("../olaf_cli_util.zig");
const types = @import("../olaf_cli_types.zig");

const debug = std.log.scoped(.olaf_cli_microphone).debug;

const print = olaf_cli_util.print;

pub const CommandInfo = struct {
    pub const name = "microphone";
    pub const description = "Query the live microphone input against the database.\n\t\tSpawns ffmpeg to capture the default microphone and streams CSV matches as they are found.\n\t\tConfigure the input via microphone_input_format / microphone_device in the config.";
    pub const help = "(no arguments; reads the default microphone via ffmpeg)";
    pub const needs_audio_files = false;
};

pub fn execute(allocator: std.mem.Allocator, args: *types.Args) !void {
    const config = args.config.?;

    // Live capture has no natural end to flush JSON, so only CSV is supported.
    if (args.output_format == .json) {
        print("The microphone command only supports live CSV output; --format json is not available.\n", .{});
        return;
    }

    const sample_rate_str = try std.fmt.allocPrint(allocator, "{d}", .{config.target_sample_rate});
    defer allocator.free(sample_rate_str);

    // Capture the configured microphone and emit f32le/mono PCM at the target
    // sample rate on stdout — matching the format the C core expects.
    const argv = [_][]const u8{
        "ffmpeg",
        "-hide_banner",
        "-loglevel",        "panic",
        "-f",               config.microphone_input_format,
        "-i",               config.microphone_device,
        "-ac",              "1",
        "-ar",              sample_rate_str,
        "-f",               "f32le",
        "-acodec",          "pcm_f32le",
        "pipe:1",
    };

    debug("Spawning ffmpeg microphone capture: -f {s} -i {s} -ar {s}", .{
        config.microphone_input_format,
        config.microphone_device,
        sample_rate_str,
    });

    const io = args.io;
    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .inherit,
    });

    // Redirect ffmpeg's PCM output onto this process's stdin (fd 0) so the C
    // stream reader (olaf_reader_stream.c) picks it up via freopen(NULL,...).
    // std.posix.dup2 was removed in 0.16; libc dup2 is available since we link libc.
    if (std.c.dup2(child.stdout.?.handle, std.posix.STDIN_FILENO) == -1) {
        return error.Dup2Failed;
    }

    // Blocks, matching and printing CSV rows live until the stream ends
    // (Ctrl+C / ffmpeg exit / EOF).
    try olaf_cli_bridge.olaf_query_stdin(allocator, "microphone", config);

    _ = child.wait(io) catch {};
}
