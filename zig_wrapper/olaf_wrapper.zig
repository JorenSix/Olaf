const std = @import("std");
const fs = std.fs;
const process = std.process;

const olaf_wrapper_config = @import("olaf_wrapper_config.zig");
const olaf_wrapper_util = @import("olaf_wrapper_util.zig");
const olaf_wrapper_util_audio = @import("olaf_wrapper_util_audio.zig");
const olaf_wrapper_bridge = @import("olaf_wrapper_bridge.zig");

const debug = std.log.scoped(.olaf_wrapper).debug;

const info = std.log.scoped(.olaf_wrapper).info;
const err = std.log.scoped(.olaf_wrapper).err;

fn print(comptime fmt: []const u8, args: anytype) void {
    // Ignore any error from printing
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    _ = stdout.print(fmt, args) catch {};
    _ = stdout.flush() catch {};
}

pub const std_options: std.Options = .{
    .log_level = .info,
};

const Args = struct {
    audio_files: std.ArrayList(olaf_wrapper_util.AudioFileWithId),
    threads: u32 = 1,
    fragmented: bool = false,
    use_audio_ids: bool = false,
    allow_identity_match: bool = true,
    skip_store: bool = false,
    force: bool = false,
    config: ?*const olaf_wrapper_config.Config = null,

    pub fn deinit(self: *Args, allocator: std.mem.Allocator) void {
        debug("Deinit Args", .{});
        for (self.audio_files.items) |item| {
            debug("Freeing audio_files item {s} {s}.", .{ item.path, item.identifier });
            item.deinit(allocator); // Do not free items, they are owned by the ArrayList
        }
        self.audio_files.deinit(allocator);
    }
};

const Command = struct {
    name: []const u8,
    description: []const u8,
    help: []const u8,
    needs_audio_files: bool,
    func: *const fn (allocator: std.mem.Allocator, args: *Args) anyerror!void,
};

const commands = [_]Command{
    .{
        .name = "to_wav",
        .description = "Converts audio from to single channel wav.\n\t--threads n\t The number of threads to use.",
        .help = "[--threads n] audio_files...",
        .needs_audio_files = true,
        .func = cmdToWav,
    },
    .{
        .name = "stats",
        .description = "Print statistics about the audio files in the database.",
        .help = "",
        .needs_audio_files = false,
        .func = cmdStats,
    },
    .{
        .name = "store",
        .description = "Extracts and stores fingerprints into an index. If --with-ids is provided, it will store audio with user provided identifiers.",
        .help = "[audio_file...] | --with-ids [audio_file audio_identifier]",
        .needs_audio_files = true,
        .func = cmdStore,
    },
    .{
        .name = "config",
        .description = "Prints the current configuration in use.",
        .help = "[audio_file...] | --with-ids [audio_file audio_identifier]",
        .needs_audio_files = false,
        .func = cmdConfig,
    },
    .{
        .name = "query",
        .description = "Query for fingerprint matches.",
        .help = "[--threads n]  [audio_file...] | --with-ids [audio_file audio_identifier]",
        .needs_audio_files = true,
        .func = cmdQuery,
    },
};

// Helper function to create a temporary raw audio file path
fn createTempRawPath(allocator: std.mem.Allocator) ![]u8 {
    // Get the system temp directory
    const tmp_dir = if (std.process.getEnvVarOwned(allocator, "TMPDIR")) |dir| dir else |_| try allocator.dupe(u8, "/tmp/");
    defer allocator.free(tmp_dir);

    // Create a subdirectory for olaf cache
    const olaf_cache_dir = try std.fmt.allocPrint(allocator, "{s}olaf_raw_audio_cache", .{tmp_dir});
    defer allocator.free(olaf_cache_dir);

    // Ensure the olaf_cache directory exists
    fs.cwd().makePath(olaf_cache_dir) catch |e| {
        if (e != error.PathAlreadyExists) return e;
    };

    // Compose the temp file path
    return try std.fmt.allocPrint(allocator, "{s}/olaf_audio_{d}.raw", .{ olaf_cache_dir, std.time.milliTimestamp() });
}

// Helper function to process an audio file and convert it to raw format
fn processAudioFile(
    allocator: std.mem.Allocator,
    audio_file_with_id: olaf_wrapper_util.AudioFileWithId,
    config: *const olaf_wrapper_config.Config,
    index: usize,
    total: usize,
    comptime action: enum { Query, Store },
) !void {
    debug("Processing audio file {d}/{d}: {s}", .{ index + 1, total, audio_file_with_id.path });

    const raw_audio_path = try createTempRawPath(allocator);
    defer allocator.free(raw_audio_path);
    defer fs.cwd().deleteFile(raw_audio_path) catch {};

    try olaf_wrapper_util_audio.convertToRaw(allocator, audio_file_with_id.path, raw_audio_path, config.target_sample_rate);

    switch (action) {
        .Query => try olaf_wrapper_bridge.olaf_query(allocator, raw_audio_path, audio_file_with_id.identifier, config),
        .Store => try olaf_wrapper_bridge.olaf_store(allocator, raw_audio_path, audio_file_with_id.identifier, config),
    }
}

fn cmdQuery(allocator: std.mem.Allocator, args: *Args) !void {
    if (args.audio_files.items.len == 0) {
        print("No audio files provided to query.\n", .{});
        return;
    }

    debug("Querying {d} audio files", .{args.audio_files.items.len});

    for (args.audio_files.items, 0..) |audio_file_with_id, i| {
        try processAudioFile(allocator, audio_file_with_id, args.config.?, i, args.audio_files.items.len, .Query);
    }
}

fn cmdConfig(_: std.mem.Allocator, args: *Args) !void {
    if (args.config) |config| {
        print("Current Olaf Configuration:\n", .{});
        try config.infoPrint();
    } else {
        print("No configuration loaded.\n", .{});
    }
}

fn cmdStore(allocator: std.mem.Allocator, args: *Args) !void {
    if (args.audio_files.items.len == 0) {
        print("No audio files provided to store.\n", .{});
        return;
    }

    debug("Storing {d} audio files", .{args.audio_files.items.len});

    for (args.audio_files.items, 0..) |audio_file_with_id, i| {
        try processAudioFile(allocator, audio_file_with_id, args.config.?, i, args.audio_files.items.len, .Store);
    }
}

fn cmdStats(allocator: std.mem.Allocator, args: *Args) !void {
    try olaf_wrapper_bridge.olaf_stats(allocator, args.config.?);
}

// Helper function to generate output filename for wav conversion
fn generateWavFilename(allocator: std.mem.Allocator, audio_path: []const u8) !struct { basename: []u8, wav_filename: []u8 } {
    const full_basename = try fs.cwd().realpathAlloc(allocator, audio_path);

    const ext_start = std.mem.lastIndexOf(u8, full_basename, ".");
    const basename = if (ext_start) |idx| full_basename[0..idx] else full_basename;

    const wav_filename = try std.fmt.allocPrint(allocator, "{s}.wav", .{basename});

    return .{ .basename = full_basename, .wav_filename = wav_filename };
}

fn cmdToWav(allocator: std.mem.Allocator, args: *Args) !void {
    // TODO: Implement parallel processing when threads > 1
    for (args.audio_files.items, 0..) |audio_file_with_id, i| {
        const names = try generateWavFilename(allocator, audio_file_with_id.path);
        defer {
            debug("Defer basename and wav_filename cleanup", .{});
            allocator.free(names.basename);
            allocator.free(names.wav_filename);
        }

        // Check if file already exists
        if (fs.cwd().statFile(names.wav_filename)) |_| {
            debug("Wav file already exists: {s}, skipping", .{names.wav_filename});
        } else |_| {
            try olaf_wrapper_util_audio.convertToWav(allocator, audio_file_with_id.path, names.wav_filename, args.config.?.target_sample_rate);
        }

        print("{d}/{d},{s},{s}\n", .{ i + 1, args.audio_files.items.len, names.basename, names.wav_filename });
    }
}

fn printCommandList() void {
    print("No such command, the following commands are valid:\n", .{});
    for (commands) |cmd| {
        print("\n{s}\t{s}\n", .{ cmd.name, cmd.description });
        print("\tolaf {s} {s}\n", .{ cmd.name, cmd.help });
    }
}

fn printHelp() !void {
    // Try to get version from executable modification date
    var exe_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = std.fs.selfExePath(&exe_path_buf) catch {
        print("Olaf - Overly Lightweight Audio Fingerprinting\n", .{});
        printCommandList();
        return;
    };

    const date = olaf_wrapper_util.getFileModificationDate(exe_path) catch {
        print("Olaf - Overly Lightweight Audio Fingerprinting\n", .{});
        printCommandList();
        return;
    };

    // If we successfully got the date, print versioned header
    print("Olaf {d}.{d:0>2}.{d:0>2} - Overly Lightweight Audio Fingerprinting\n", .{ date.year, date.month, date.day });
    printCommandList();
}

pub fn main() !void {
    //const allocator = std.heap.page_allocator;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var config = try olaf_wrapper_config.olafWrapperConfig(allocator);
    defer {
        debug("Defer config cleanup", .{});
        config.deinit(allocator);
    }
    config.debugPrint();

    const args_list = try process.argsAlloc(allocator);
    defer process.argsFree(allocator, args_list);

    debug("Number of arguments: {d}", .{args_list.len});
    for (args_list, 0..) |arg, index| {
        debug("args[{d}]: \"{s}\"", .{ index, arg });
    }

    if (args_list.len < 2) {
        try printHelp();
        return;
    }

    // Create directories if they don't exist
    const db_path = try olaf_wrapper_util.expandPath(allocator, config.db_folder);
    debug("DB path: {s}", .{db_path});
    defer allocator.free(db_path);
    fs.cwd().makePath(db_path) catch |errr| {
        if (errr != error.PathAlreadyExists) return errr;
    };

    const cache_path = try olaf_wrapper_util.expandPath(allocator, config.cache_folder);
    defer allocator.free(cache_path);
    debug("Cache path: {s}", .{cache_path});
    fs.cwd().makePath(cache_path) catch |errr| {
        if (errr != error.PathAlreadyExists) return errr;
    };

    const command_name = args_list[1];
    debug("Command name: {s}", .{command_name});

    var args = Args{
        .audio_files = std.ArrayList(olaf_wrapper_util.AudioFileWithId){},
    };

    args.config = &config;

    defer {
        debug("Deinit Args", .{});
        args.deinit(allocator);
    }

    var i: usize = 2;
    while (i < args_list.len) : (i += 1) {
        const arg = args_list[i];

        if (std.mem.eql(u8, arg, "--threads")) {
            if (i + 1 < args_list.len) {
                args.threads = try std.fmt.parseInt(u32, args_list[i + 1], 10);
                i += 1;
            } else {
                print("Expected a numeric argument for '--threads': 'olaf cache files --threads 8'\n", .{});
                return;
            }
        } else if (std.mem.eql(u8, arg, "--no-identity-match")) {
            args.allow_identity_match = false;
        } else if (std.mem.eql(u8, arg, "--with-ids") or std.mem.eql(u8, arg, "--with_ids")) {
            args.use_audio_ids = true;
        } else if (std.mem.eql(u8, arg, "--fragmented")) {
            args.fragmented = true;
        } else if (std.mem.eql(u8, arg, "--skip-store") or std.mem.eql(u8, arg, "--skip_store")) {
            args.skip_store = true;
        } else if (std.mem.eql(u8, arg, "-f")) {
            args.force = true;
        } else {
            // It's an unrecognized argument, a file?
            if (args.use_audio_ids) {
                try olaf_wrapper_util.audioFileListWithId(allocator, arg, args_list[i + 1], &args.audio_files, config.allowed_audio_file_extensions);
                i += 1; // Skip the next argument as it is the audio identifier
            } else {
                try olaf_wrapper_util.audioFileList(allocator, arg, &args.audio_files, config.allowed_audio_file_extensions);
            }
        }
    }

    // Find and execute command
    for (commands) |cmd| {
        if (std.mem.eql(u8, cmd.name, command_name)) {
            if (cmd.needs_audio_files and args.audio_files.items.len == 0) {
                print("This command needs audio files, none are found.\n", .{});
                print("olaf {s} {s}\n", .{ cmd.name, cmd.help });

                return;
            }

            try cmd.func(allocator, &args);

            return;
        }
    }

    // Command not found
    try printHelp();
}
