const std = @import("std");
const fs = std.fs;
const process = std.process;

const types = @import("olaf_wrapper_types.zig");
const olaf_wrapper_config = @import("olaf_wrapper_config.zig");
const olaf_wrapper_util = @import("olaf_wrapper_util.zig");

// Import command modules
const cmd_query = @import("olaf_wrapper_commands/query.zig");
const cmd_store = @import("olaf_wrapper_commands/store.zig");
const cmd_stats = @import("olaf_wrapper_commands/stats.zig");
const cmd_config = @import("olaf_wrapper_commands/config.zig");
const cmd_to_wav = @import("olaf_wrapper_commands/to_wav.zig");

const debug = std.log.scoped(.olaf_wrapper).debug;

fn print(comptime fmt: []const u8, args: anytype) void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    _ = stdout.print(fmt, args) catch {};
    _ = stdout.flush() catch {};
}

pub const std_options: std.Options = .{
    .log_level = .info,
};

const Command = struct {
    name: []const u8,
    description: []const u8,
    help: []const u8,
    needs_audio_files: bool,
    func: *const fn (allocator: std.mem.Allocator, args: *types.Args) anyerror!void,
};

const commands = [_]Command{
    .{
        .name = cmd_to_wav.CommandInfo.name,
        .description = cmd_to_wav.CommandInfo.description,
        .help = cmd_to_wav.CommandInfo.help,
        .needs_audio_files = cmd_to_wav.CommandInfo.needs_audio_files,
        .func = cmd_to_wav.execute,
    },
    .{
        .name = cmd_stats.CommandInfo.name,
        .description = cmd_stats.CommandInfo.description,
        .help = cmd_stats.CommandInfo.help,
        .needs_audio_files = cmd_stats.CommandInfo.needs_audio_files,
        .func = cmd_stats.execute,
    },
    .{
        .name = cmd_store.CommandInfo.name,
        .description = cmd_store.CommandInfo.description,
        .help = cmd_store.CommandInfo.help,
        .needs_audio_files = cmd_store.CommandInfo.needs_audio_files,
        .func = cmd_store.execute,
    },
    .{
        .name = cmd_config.CommandInfo.name,
        .description = cmd_config.CommandInfo.description,
        .help = cmd_config.CommandInfo.help,
        .needs_audio_files = cmd_config.CommandInfo.needs_audio_files,
        .func = cmd_config.execute,
    },
    .{
        .name = cmd_query.CommandInfo.name,
        .description = cmd_query.CommandInfo.description,
        .help = cmd_query.CommandInfo.help,
        .needs_audio_files = cmd_query.CommandInfo.needs_audio_files,
        .func = cmd_query.execute,
    },
};

fn printCommandList() void {
    print("No such command, the following commands are valid:\n", .{});
    for (commands) |cmd| {
        print("\n{s}\t{s}\n", .{ cmd.name, cmd.description });
        print("\tolaf {s} {s}\n", .{ cmd.name, cmd.help });
    }
}

fn printHelp() !void {
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

    print("Olaf {d}.{d:0>2}.{d:0>2} - Overly Lightweight Audio Fingerprinting\n", .{ date.year, date.month, date.day });
    printCommandList();
}

pub fn main() !void {
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

    var args = types.Args{
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
