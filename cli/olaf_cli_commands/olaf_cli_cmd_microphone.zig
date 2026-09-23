const std = @import("std");
const builtin = @import("builtin");
const olaf_cli_session = @import("../olaf_cli_session.zig");
const olaf_cli_util = @import("../olaf_cli_util.zig");
const types = @import("../olaf_cli_types.zig");

const debug = std.log.scoped(.olaf_cli_microphone).debug;

const print = olaf_cli_util.print;

pub const CommandInfo = struct {
    pub const name = "microphone";
    pub const description = "Query the live microphone input against the database.\n\t\tSpawns ffmpeg to capture the default microphone and streams CSV matches as they are found.\n\t\tConfigure the input via microphone_input_format / microphone_device in the config.\n\t\tResults print every print_result_every s (default 3) and matches expire after keep_matches_for s (default 10).";
    pub const help = "(no arguments; reads the default microphone via ffmpeg)";
    pub const needs_audio_files = false;
};

pub fn execute(allocator: std.mem.Allocator, args: *types.Args) !void {
    // The stdin redirection below (dup2 onto fd 0) is POSIX-only; on Windows
    // fd_t is a HANDLE so this code does not even compile. The comptime
    // if/else keeps the POSIX body out of Windows analysis entirely.
    if (builtin.os.tag == .windows) {
        print("The microphone command is not supported on Windows.\n", .{});
        return;
    } else {
        const config = args.config.?;

        // Live capture has no natural end to flush JSON, so only CSV is supported.
        if (args.queryFormat() == .json) {
            print("The microphone command only supports live CSV output; --format json is not available.\n", .{});
            return error.Usage;
        }

        const sample_rate_str = try std.fmt.allocPrint(allocator, "{d}", .{config.target_sample_rate});
        defer allocator.free(sample_rate_str);

        // Capture the configured microphone and emit f32le/mono PCM at the target
        // sample rate on stdout — matching the format the C core expects.
        const argv = [_][]const u8{
            "ffmpeg",
            "-hide_banner",
            // "error", not "panic": a wrong input format, missing device or
            // denied microphone permission must reach the user.
            "-loglevel",        "error",
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
        const pipe_fd = child.stdout.?.handle;
        if (std.c.dup2(pipe_fd, std.posix.STDIN_FILENO) == -1) {
            return error.Dup2Failed;
        }
        // fd 0 now owns the pipe; drop the original so wait() does not close
        // it a second time.
        _ = std.c.close(pipe_fd);
        child.stdout = null;

        // Blocks, matching and printing CSV rows live until the stream ends
        // (Ctrl+C / ffmpeg exit / EOF).
        try olaf_cli_session.queryStdin(allocator, "microphone", config);

        // A capture that ends on its own is ffmpeg failing (bad input format,
        // no device, no permission); report it instead of exiting silently.
        const term = child.wait(io) catch |err| {
            std.log.err("microphone capture: waiting for ffmpeg failed: {}", .{err});
            return error.ProcessingFailed;
        };
        const ok = switch (term) {
            .exited => |code| code == 0,
            .signal => |sig| sig == .INT,
            else => false,
        };
        if (!ok) {
            var how_buf: [64]u8 = undefined;
            const how = switch (term) {
                .exited => |code| std.fmt.bufPrint(&how_buf, "exit code {d}", .{code}) catch "an error",
                .signal => |sig| std.fmt.bufPrint(&how_buf, "signal {s}", .{@tagName(sig)}) catch "a signal",
                else => "an abnormal termination",
            };
            std.log.err("microphone capture failed: ffmpeg ended with {s} (input format '{s}', device '{s}'); set microphone_input_format / microphone_device in the config", .{
                how, config.microphone_input_format, config.microphone_device,
            });
            return error.ProcessingFailed;
        }
    }
}
