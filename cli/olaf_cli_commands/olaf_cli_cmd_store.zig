const std = @import("std");
const olaf_cli_threading = @import("../olaf_cli_threading.zig");
const olaf_cli_bridge = @import("../olaf_cli_bridge.zig");
const types = @import("../olaf_cli_types.zig");

const debug = std.log.scoped(.olaf_cli_store).debug;

fn print(comptime fmt: []const u8, args: anytype) void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    _ = stdout.print(fmt, args) catch {};
    _ = stdout.flush() catch {};
}

pub const CommandInfo = struct {
    pub const name = "store";
    pub const description = "Extracts and stores fingerprints into an index. If --with-ids is provided, it will store audio with user provided identifiers.\n\t\t--threads n\t The number of threads to use.\n\t\t--format <human|csv|json>\t Per-file summary format on stderr (default: human).";
    pub const help = "[--threads n] [--format <human|csv|json>] [audio_file...] | --with-ids [[audio_file audio_identifier] ...]";
    pub const needs_audio_files = true;
};

pub fn execute(allocator: std.mem.Allocator, args: *types.Args) !void {
    if (args.audio_files.items.len == 0) {
        print("No audio files provided to store.\n", .{});
        return;
    }

    // CSV: emit a single header row before any worker starts so consumers
    // can parse it with csv.DictReader. JSON is NDJSON (no header) and
    // human keeps its legacy free-form sentence per file.
    if (args.store_format == .csv) {
        var stderr = std.fs.File.stderr();
        try stderr.writeAll(olaf_cli_bridge.store_csv_header);
    }

    try olaf_cli_threading.executeParallel(
        allocator,
        args.audio_files.items,
        args.config.?,
        .Store,
        args.threads,
        true,
        .csv,
        args.store_format,
    );
}
