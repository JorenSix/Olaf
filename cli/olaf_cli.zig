const std = @import("std");
const Io = std.Io;

const types = @import("olaf_cli_types.zig");
const olaf_cli_config = @import("olaf_cli_config.zig");
const olaf_cli_util = @import("olaf_cli_util.zig");
const olaf_cli_output = @import("olaf_cli_output.zig");
const olaf_cli_threading = @import("olaf_cli_threading.zig");

// Import command modules
const cmd_query = @import("olaf_cli_commands/olaf_cli_cmd_query.zig");
const cmd_store = @import("olaf_cli_commands/olaf_cli_cmd_store.zig");
const cmd_stats = @import("olaf_cli_commands/olaf_cli_cmd_stats.zig");
const cmd_config = @import("olaf_cli_commands/olaf_cli_cmd_config.zig");
const cmd_to_wav = @import("olaf_cli_commands/olaf_cli_cmd_to_wav.zig");
const cmd_to_raw = @import("olaf_cli_commands/olaf_cli_cmd_to_raw.zig");
const cmd_clear = @import("olaf_cli_commands/olaf_cli_cmd_clear.zig");
const cmd_delete = @import("olaf_cli_commands/olaf_cli_cmd_delete.zig");
const cmd_cache = @import("olaf_cli_commands/olaf_cli_cmd_cache.zig");
const cmd_store_cached = @import("olaf_cli_commands/olaf_cli_cmd_store_cached.zig");
const cmd_dedup = @import("olaf_cli_commands/olaf_cli_cmd_dedup.zig");
const cmd_microphone = @import("olaf_cli_commands/olaf_cli_cmd_microphone.zig");

const debug = std.log.scoped(.olaf_cli).debug;

const print = olaf_cli_util.print;

pub const std_options: std.Options = .{
    .log_level = .info,
};

/// Returned for invalid command-line usage; `main` maps it to exit status 2.
pub const UsageError = error{Usage};

const Command = struct {
    name: []const u8,
    description: []const u8,
    help: []const u8,
    needs_audio_files: bool,
    flags: []const types.Flag,
    func: *const fn (allocator: std.mem.Allocator, args: *types.Args) anyerror!void,
};

/// A command module exports `CommandInfo` (name, description, help,
/// needs_audio_files) and `execute`.
fn command(comptime m: type) Command {
    return .{
        .name = m.CommandInfo.name,
        .description = m.CommandInfo.description,
        .help = m.CommandInfo.help,
        .needs_audio_files = m.CommandInfo.needs_audio_files,
        .flags = m.CommandInfo.flags,
        .func = m.execute,
    };
}

const commands = [_]Command{
    command(cmd_microphone),
    command(cmd_to_wav),
    command(cmd_to_raw),
    command(cmd_stats),
    command(cmd_store),
    command(cmd_config),
    command(cmd_query),
    command(cmd_clear),
    command(cmd_delete),
    command(cmd_cache),
    command(cmd_store_cached),
    command(cmd_dedup),
};

fn printCommandList() void {
    print("The following commands are valid:\n", .{});
    for (commands) |cmd| {
        print("\n{s}\t{s}\n", .{ cmd.name, cmd.description });
        print("\tolaf {s} {s}\n", .{ cmd.name, cmd.help });
    }
}

fn printHelp(io: Io) !void {
    var exe_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path_len = std.process.executablePath(io, &exe_path_buf) catch {
        print("Olaf - Overly Lightweight Audio Fingerprinting\n", .{});
        printCommandList();
        return;
    };
    const exe_path = exe_path_buf[0..exe_path_len];

    const date = olaf_cli_util.getFileModificationDate(io, exe_path) catch {
        print("Olaf - Overly Lightweight Audio Fingerprinting\n", .{});
        printCommandList();
        return;
    };

    print("Olaf {d}.{d:0>2}.{d:0>2} - Overly Lightweight Audio Fingerprinting\n", .{ date.year, date.month, date.day });
    printCommandList();
}

pub fn main(init: std.process.Init) !u8 {
    run(init) catch |err| switch (err) {
        error.Usage => return 2,
        // Per-file failures were already logged; skip the redundant trace.
        error.ProcessingFailed => return 1,
        // The offending setting was already logged by the config loader.
        error.InvalidConfigValue => return 1,
        error.NoHomeDirectory => return 1,
        error.DatabaseNotWritable => return 1,
        else => return err,
    };
    return 0;
}

fn run(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // Resolve $HOME once (the process environment is no longer globally
    // accessible in 0.16); threaded into config/path expansion.
    // HOME on POSIX, USERPROFILE on Windows (where HOME is usually unset).
    const home: ?[]const u8 = init.minimal.environ.getAlloc(allocator, "HOME") catch
        init.minimal.environ.getAlloc(allocator, "USERPROFILE") catch null;
    defer if (home) |h| allocator.free(h);

    // Temp raw audio (about 3.8 MB per minute of audio, per worker) goes
    // where the user points temporary files, not always to /tmp.
    // An empty value (TMPDIR=) counts as unset: it would put the temp files
    // in the current directory.
    const tmp_dir: ?[]const u8 = for ([_][]const u8{ "TMPDIR", "TEMP", "TMP" }) |name| {
        const v = init.minimal.environ.getAlloc(allocator, name) catch continue;
        if (v.len > 0) break v;
        allocator.free(v);
    } else null;
    defer if (tmp_dir) |t| allocator.free(t);
    if (tmp_dir) |t| olaf_cli_threading.setTempRoot(t);

    var config = try olaf_cli_config.olafWrapperConfig(allocator, io, home);
    defer {
        debug("Defer config cleanup", .{});
        config.deinit();
    }
    config.debugPrint();

    const args_list = try init.minimal.args.toSlice(init.arena.allocator());

    debug("Number of arguments: {d}", .{args_list.len});
    for (args_list, 0..) |arg, index| {
        debug("args[{d}]: \"{s}\"", .{ index, arg });
    }

    // Create directories if they don't exist. Done before the no-args branch
    // so the TUI can read database stats from an existing db folder.
    const db_path = try olaf_cli_util.expandPath(allocator, home, config.db_folder);
    debug("DB path: {s}", .{db_path});
    defer allocator.free(db_path);
    Io.Dir.cwd().createDirPath(io, db_path) catch |errr| {
        if (errr != error.PathAlreadyExists) return errr;
    };

    const cache_path = try olaf_cli_util.expandPath(allocator, home, config.cache_folder);
    defer allocator.free(cache_path);
    debug("Cache path: {s}", .{cache_path});
    Io.Dir.cwd().createDirPath(io, cache_path) catch |errr| {
        if (errr != error.PathAlreadyExists) return errr;
    };

    // No arguments: launch the interactive TUI (ncdu-style browser + db panel).
    if (args_list.len < 2) {
        try @import("tui/olaf_tui.zig").run(allocator, io, init.environ_map, &config);
        return;
    }

    const command_name = args_list[1];
    debug("Command name: {s}", .{command_name});

    if (std.mem.eql(u8, command_name, "help") or std.mem.eql(u8, command_name, "--help") or std.mem.eql(u8, command_name, "-h")) {
        try printHelp(io);
        return;
    }


    const cmd = for (commands) |cmd| {
        if (std.mem.eql(u8, cmd.name, command_name)) break cmd;
    } else {
        print("No such command: '{s}'\n", .{command_name});
        try printHelp(io);
        return error.Usage;
    };

    var args = try parseArgs(allocator, io, home, &config, cmd, args_list[2..]);
    defer args.deinit(allocator);

    if (cmd.needs_audio_files and args.audio_files.items.len == 0) {
        print("This command needs audio files, none are found.\n", .{});
        print("olaf {s} {s}\n", .{ cmd.name, cmd.help });
        return error.Usage;
    }
    try cmd.func(allocator, &args);
}

/// Parse the arguments after the command name: flags into `Args`, everything
/// else resolved to audio files (or `--with-ids` file/identifier pairs).
fn parseArgs(allocator: std.mem.Allocator, io: Io, home: ?[]const u8, config: *const olaf_cli_config.Config, cmd: Command, args_list: []const [:0]const u8) !types.Args {
    var args = types.Args{ .audio_files = .empty, .io = io, .config = config };
    errdefer args.deinit(allocator);

    var i: usize = 0;
    while (i < args_list.len) : (i += 1) {
        const arg = args_list[i];

        if (std.mem.eql(u8, arg, "--threads")) {
            try allow(cmd, .threads, arg);
            if (i + 1 < args_list.len) {
                const threads_arg = args_list[i + 1];
                args.threads = std.fmt.parseInt(u32, threads_arg, 10) catch 0;
                if (args.threads == 0) {
                    print("'--threads' expects a positive integer, got '{s}'\n", .{threads_arg});
                    return error.Usage;
                }
                i += 1;
            } else {
                print("Expected a numeric argument for '--threads': 'olaf cache files --threads 8'\n", .{});
                return error.Usage;
            }
        } else if (std.mem.eql(u8, arg, "--no-identity-match")) {
            try allow(cmd, .no_identity_match, arg);
            args.allow_identity_match = false;
        } else if (std.mem.eql(u8, arg, "--with-ids") or std.mem.eql(u8, arg, "--with_ids")) {
            try allow(cmd, .with_ids, arg);
            args.use_audio_ids = true;
        } else if (std.mem.eql(u8, arg, "--fragmented")) {
            try allow(cmd, .fragmented, arg);
            args.fragmented = true;
        } else if (std.mem.eql(u8, arg, "--skip-store") or std.mem.eql(u8, arg, "--skip_store")) {
            try allow(cmd, .skip_store, arg);
            args.skip_store = true;
        } else if (std.mem.eql(u8, arg, "--format")) {
            try allow(cmd, .format, arg);
            if (i + 1 < args_list.len) {
                const fmt = args_list[i + 1];
                args.format = std.meta.stringToEnum(olaf_cli_output.Format, fmt) orelse {
                    print("Unknown --format value '{s}', expected 'csv', 'json', or 'human'.\n", .{fmt});
                    return error.Usage;
                };
                i += 1;
            } else {
                print("Expected an argument for '--format': 'olaf query --format json file.mp3'\n", .{});
                return error.Usage;
            }
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
            try allow(cmd, .force, arg);
            args.force = true;
        } else {
            // Not an option: an audio file (or an unknown option).
            if (arg.len > 1 and arg[0] == '-') {
                print("Unknown option '{s}' for 'olaf {s}'.\nolaf {s} {s}\n", .{ arg, cmd.name, cmd.name, cmd.help });
                return error.Usage;
            }
            if (!cmd.needs_audio_files) {
                print("'olaf {s}' takes no audio files (got '{s}').\n", .{ cmd.name, arg });
                return error.Usage;
            }
            if (args.use_audio_ids) {
                if (i + 1 >= args_list.len or (args_list[i + 1].len > 1 and args_list[i + 1][0] == '-')) {
                    print("--with-ids expects pairs: audio_file audio_identifier ('{s}' has no identifier)\n", .{arg});
                    return error.Usage;
                }
                try olaf_cli_util.audioFileListWithId(allocator, io, home, arg, args_list[i + 1], &args.audio_files, config.allowed_audio_file_extensions);
                i += 1; // Skip the next argument as it is the audio identifier
            } else {
                try olaf_cli_util.audioFileList(allocator, io, home, arg, &args.audio_files, config.allowed_audio_file_extensions);
            }
        }
    }
    return args;
}

/// Reject an option the command does not support.
fn allow(cmd: Command, flag: types.Flag, arg: []const u8) !void {
    if (std.mem.indexOfScalar(types.Flag, cmd.flags, flag) != null) return;
    print("'{s}' is not an option of 'olaf {s}'.\nolaf {s} {s}\n", .{ arg, cmd.name, cmd.name, cmd.help });
    return error.Usage;
}
