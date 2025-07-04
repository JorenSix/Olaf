const std = @import("std");
const fs = std.fs;
const process = std.process;

const olaf_wrapper_config = @import("olaf_wrapper_config.zig");
const olaf_wrapper_util = @import("olaf_wrapper_util.zig");

const debug = std.log.scoped(.olaf_wrapper).debug;
const err = std.log.scoped(.olaf_wrapper).err;

fn print(comptime fmt: []const u8, args: anytype) void {
    // Ignore any error from printing
    _ = std.io.getStdOut().writer().print(fmt, args) catch {};
}

const Args = struct {
    audio_files: std.ArrayList([]const u8),
    threads: u32 = 1,
    fragmented: bool = false,
    allow_identity_match: bool = true,
    skip_store: bool = false,
    force: bool = false,
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
};

fn cmdToWav(allocator: std.mem.Allocator, _: *const olaf_wrapper_config.Config, args: *Args) !void {
    // TODO: Implement parallel processing when threads > 1
    for (args.audio_files.items, 0..) |raw_file, i| {
        const full_basename = std.fs.path.basename(raw_file);
        const ext_start = std.mem.lastIndexOf(u8, full_basename, ".");
        const basename = if (ext_start) |idx| full_basename[0..idx] else full_basename;

        const wav_filename = try std.fmt.allocPrint(allocator, "{s}.wav", .{basename});
        print("{d}/{d},{s},{s}\n", .{ i + 1, args.audio_files.items.len, full_basename, wav_filename });
        allocator.free(wav_filename); // <-- Free after use!
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

const olaf = @cImport({
    @cInclude("olaf_wrapper_bridge.h");
});

fn olaf_main_wrapped(allocator: std.mem.Allocator) !void {
    const args_list = try process.argsAlloc(allocator);
    defer process.argsFree(allocator, args_list);

    var c_argv = try allocator.alloc([*c]const u8, args_list.len);
    defer allocator.free(c_argv);
    for (args_list, 0..) |arg, i| {
        c_argv[i] = arg.ptr;
    }
    _ = olaf.olaf_main(@intCast(args_list.len), c_argv.ptr);
    debug("olaf main", .{});
}

pub fn main() !void {
    //const allocator = std.heap.page_allocator;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    debug("Starting olaf_wrapper...", .{});
    try olaf_main_wrapped(allocator);

    var config = try olaf_wrapper_config.olafWrapperConfig(allocator);
    defer {
        debug("Defer config cleanup", .{});
        config.deinit(allocator);
    }

    debug("Loaded config:", .{});
    debug("DB folder: {s}", .{config.db_folder});
    debug("Cache folder: {s}", .{config.cache_folder});
    debug("Executable: {s}", .{config.executable_location});
    debug("Check incoming audio: {any}", .{config.check_incoming_audio});
    debug("Skip duplicates: {any}", .{config.skip_duplicates});
    debug("Fragment duration: {d}", .{config.fragment_duration_in_seconds});
    debug("Target sample rate: {d}", .{config.target_sample_rate});
    debug("Allowed extensions: ", .{});
    for (config.allowed_audio_file_extensions) |ext| {
        debug("{s} ", .{ext});
    }
    debug("\n", .{});

    const args_list = try process.argsAlloc(allocator);
    defer process.argsFree(allocator, args_list);

    if (args_list.len < 2) {
        try printHelp(args_list[0]);
        return;
    }

    // Create directories if they don't exist
    const db_path = try olaf_wrapper_util.expandPath(allocator, config.db_folder);
    defer allocator.free(db_path);
    const cache_path = try olaf_wrapper_util.expandPath(allocator, config.cache_folder);
    defer allocator.free(cache_path);

    fs.cwd().makePath(db_path) catch |errr| {
        if (errr != error.PathAlreadyExists) return errr;
    };
    fs.cwd().makePath(cache_path) catch |errr| {
        if (errr != error.PathAlreadyExists) return errr;
    };

    const command_name = args_list[1];

    // Parse arguments
    var args = Args{
        .audio_files = std.ArrayList([]const u8).init(allocator),
    };
    defer {
        debug("Defer audio files cleanup", .{});
        for (args.audio_files.items) |item| {
            allocator.free(item);
        }
        args.audio_files.deinit();
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
