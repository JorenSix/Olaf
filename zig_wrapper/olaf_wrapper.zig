const std = @import("std");
const fs = std.fs;
const process = std.process;

const olaf_wrapper_config = @import("olaf_wrapper_config.zig");
const olaf_wrapper_util = @import("olaf_wrapper_util.zig");
const olaf_wrapper_bridge = @import("olaf_wrapper_bridge.zig");

const debug = std.log.scoped(.olaf_wrapper).debug;

const info = std.log.scoped(.olaf_wrapper).info;
const err = std.log.scoped(.olaf_wrapper).err;

fn print(comptime fmt: []const u8, args: anytype) void {
    // Ignore any error from printing
    _ = std.io.getStdOut().writer().print(fmt, args) catch {};
}

pub const std_options: std.Options = .{
    .log_level = .debug,
};

const Args = struct {
    audio_files: std.ArrayList([]const u8),
    threads: u32 = 1,
    fragmented: bool = false,
    allow_identity_match: bool = true,
    skip_store: bool = false,
    force: bool = false,

    pub fn deinit(self: *Args, allocator: std.mem.Allocator) void {
        debug("Deinit Args", .{});
        for (self.audio_files.items) |item| {
            debug("Freeing audio_files item {s}", .{item});
            allocator.free(item); // Do not free items, they are owned by the ArrayList
        }
        self.audio_files.deinit();
    }
};

const Command = struct {
    name: []const u8,
    description: []const u8,
    help: []const u8,
    needs_audio_files: bool,
    func: *const fn (allocator: std.mem.Allocator, config: *const olaf_wrapper_config.Config, args: *Args) anyerror!void,
};

const commands = [_]Command{
    .{
        .name = "to_wav",
        .description = "Converts audio from the RAW format olaf understands to wav.\n\t--threads n\t The number of threads to use.",
        .help = "[--threads n] audio_files...",
        .needs_audio_files = true,
        .func = cmdToWav,
    },
    .{
        .name = "stats",
        .description = "Print statistics about the audio files in the database.",
        .help = "[--threads n] audio_files...",
        .needs_audio_files = false,
        .func = cmdStats,
    },
};

fn cmdStats(_: std.mem.Allocator, _: *const olaf_wrapper_config.Config, _: *Args) !void {
    try olaf_wrapper_bridge.olaf_stats();
}

fn cmdToWav(allocator: std.mem.Allocator, _: *const olaf_wrapper_config.Config, args: *Args) !void {
    // TODO: Implement parallel processing when threads > 1
    for (args.audio_files.items, 0..) |raw_file, i| {
        const full_basename = try fs.cwd().realpathAlloc(allocator, raw_file);
        defer {
            debug("Defer full_basename cleanup", .{});
            allocator.free(full_basename);
        }

        const ext_start = std.mem.lastIndexOf(u8, full_basename, ".");
        const basename = if (ext_start) |idx| full_basename[0..idx] else full_basename;

        const wav_filename = try std.fmt.allocPrint(allocator, "{s}.wav", .{basename});
        defer {
            debug("Defer wav_filename cleanup", .{});
            allocator.free(wav_filename);
        }

        print("{d}/{d},{s},{s}\n", .{ i + 1, args.audio_files.items.len, full_basename, wav_filename });
    }
}

fn printHelp(exe_path: []const u8) !void {
    const date = try olaf_wrapper_util.getFileModificationDate(exe_path);
    const year = date.year;
    const month = date.month;
    const day = date.day;

    print("Olaf {d}.{d:0>2}.{d:0>2} - Overly Lightweight Audio Fingerprinting\n", .{ year, month, day });
    print("No such command, the following commands are valid:\n", .{});

    for (commands) |cmd| {
        print("\n{s}\t{s}\n", .{ cmd.name, cmd.description });
        print("\tolaf {s} {s}\n", .{ cmd.name, cmd.help });
    }
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
        try printHelp(args_list[0]);
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
        .audio_files = std.ArrayList([]const u8).init(allocator),
    };

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
        } else if (std.mem.eql(u8, arg, "--fragmented")) {
            args.fragmented = true;
        } else if (std.mem.eql(u8, arg, "--skip-store") or std.mem.eql(u8, arg, "--skip_store")) {
            args.skip_store = true;
        } else if (std.mem.eql(u8, arg, "-f")) {
            args.force = true;
        } else {
            // It's an audio file argument
            try olaf_wrapper_util.audioFileList(allocator, arg, &args.audio_files, config.allowed_audio_file_extensions);
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

            try cmd.func(allocator, &config, &args);

            return;
        }
    }

    // Command not found
    try printHelp(args_list[0]);
}
