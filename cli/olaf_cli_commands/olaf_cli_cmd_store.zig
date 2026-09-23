const std = @import("std");
const olaf_cli_threading = @import("../olaf_cli_threading.zig");
const olaf_cli_core = @import("../olaf_cli_core.zig");
const olaf_cli_output = @import("../olaf_cli_output.zig");
const olaf_cli_session = @import("../olaf_cli_session.zig");
const olaf_cli_util = @import("../olaf_cli_util.zig");
const types = @import("../olaf_cli_types.zig");

const debug = std.log.scoped(.olaf_cli_store).debug;

const print = olaf_cli_util.print;

pub const CommandInfo = struct {
    pub const name = "store";
    pub const description = "Extracts and stores fingerprints into an index. If --with-ids is provided, it will store audio with user provided identifiers.\n\t\tAlready indexed files are skipped when skip_duplicates is set (default).\n\t\t-f, --force\t Re-store files that are already indexed.\n\t\t--threads n\t The number of threads to use.\n\t\t--format <human|csv|json>\t Per-file summary format on stderr (default: human).";
    pub const help = "[-f] [--threads n] [--format <human|csv|json>] [audio_file...] | --with-ids [[audio_file audio_identifier] ...]";
    pub const needs_audio_files = true;
    pub const flags = &[_]types.Flag{ .threads, .format, .force, .with_ids };
};

pub fn execute(allocator: std.mem.Allocator, args: *types.Args) !void {
    if (args.audio_files.items.len == 0) {
        print("No audio files provided to store.\n", .{});
        return;
    }

    // CSV: emit a single header row before any worker starts so consumers
    // can parse it with csv.DictReader. JSON is NDJSON (no header) and
    // human keeps its legacy free-form sentence per file.
    if (args.storeFormat() == .csv) {
        try std.Io.File.stderr().writeStreamingAll(args.io, olaf_cli_output.store_csv_header);
    }

    try storeFiles(allocator, args);
}

/// Store `args.audio_files`, skipping files that are already indexed when
/// `skip_duplicates` is configured and `--force` is not given. Shared with
/// the store step of `dedup`.
pub fn storeFiles(allocator: std.mem.Allocator, args: *types.Args) !void {
    const config = args.config.?;
    const all = args.audio_files.items;

    var to_store: std.ArrayList(olaf_cli_util.AudioFileWithId) = .empty;
    defer to_store.deinit(allocator);

    if (config.skip_duplicates and !args.force) {
        const identifiers = try allocator.alloc([]const u8, all.len);
        defer allocator.free(identifiers);
        for (all, identifiers) |f, *id| id.* = f.identifier;

        const stored = try olaf_cli_session.storedFlags(allocator, config, identifiers);
        defer allocator.free(stored);

        for (all, stored) |f, is_stored| {
            if (is_stored) {
                const internal_id = olaf_cli_core.nameToId(f.identifier);
                try olaf_cli_output.writeStoreSkip(args.storeFormat(), f.identifier, internal_id);
            } else {
                try to_store.append(allocator, f);
            }
        }
        debug("Skipped {d} already indexed file(s)", .{all.len - to_store.items.len});
    } else {
        try to_store.appendSlice(allocator, all);
    }

    if (to_store.items.len == 0) return;

    try olaf_cli_threading.executeParallel(
        args.io,
        allocator,
        to_store.items,
        config,
        .Store,
        args.threads,
        true,
        .csv,
        args.storeFormat(),
    );
}
