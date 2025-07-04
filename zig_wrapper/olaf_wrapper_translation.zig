const std = @import("std");
const builtin = @import("builtin");
const fs = std.fs;
const process = std.process;
const print = std.debug.print;

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8) !struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
} {
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    // Use ArrayList to collect output as it streams in
    var stdout_list = std.ArrayList(u8).init(allocator);
    defer stdout_list.deinit();
    var stderr_list = std.ArrayList(u8).init(allocator);
    defer stderr_list.deinit();

    var stdout_reader = child.stdout.?.reader();
    var stderr_reader = child.stderr.?.reader();

    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;

    // Read both streams until EOF
    var stdout_done = false;
    var stderr_done = false;
    while (!stdout_done or !stderr_done) {
        if (!stdout_done) {
            const n = stdout_reader.read(&stdout_buf) catch |err| return err;
            if (n == 0) {
                stdout_done = true;
            } else {
                //print the output to stdout
                std.debug.print("{s}", .{stdout_buf[0..n]}); // Uncomment to print stdout in real-time
                try stdout_list.appendSlice(stdout_buf[0..n]);
            }
        }
        if (!stderr_done) {
            const n = stderr_reader.read(&stderr_buf) catch |err| return err;
            if (n == 0) {
                stderr_done = true;
            } else {
                try stderr_list.appendSlice(stderr_buf[0..n]);
            }
        }
    }

    const term = try child.wait();

    return .{
        .term = term,
        .stdout = try stdout_list.toOwnedSlice(),
        .stderr = try stderr_list.toOwnedSlice(),
    };
}

fn runCommandPiped(allocator: std.mem.Allocator, argv: []const []const u8, stdin_data: ?[]const u8) !struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
} {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = if (stdin_data != null) .Pipe else .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    if (stdin_data) |data| {
        if (child.stdin) |stdin| {
            try stdin.writeAll(data);
            stdin.close();
        }
    }

    const stdout = try child.stdout.?.reader().readAllAlloc(allocator, 10 * 1024 * 1024);
    const stderr = try child.stderr.?.reader().readAllAlloc(allocator, 10 * 1024 * 1024);

    const term = try child.wait();

    return .{
        .term = term,
        .stdout = stdout,
        .stderr = stderr,
    };
}

fn has(allocator: std.mem.Allocator, config: *const Config, audio_file: []const u8) !bool {
    const db_path = try expandPath(allocator, config.db_folder);
    defer allocator.free(db_path);

    var dir = fs.cwd().openDir(db_path, .{ .iterate = true }) catch return false;
    defer dir.close();

    var it = dir.iterate();
    const has_files = (try it.next()) != null;
    if (!has_files) return false;

    const result = try runCommand(allocator, &.{ config.executable_location, "has", audio_file });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    if (result.stdout.len == 0) return false;

    var lines = std.mem.tokenizeAny(u8, result.stdout, "\n");
    _ = lines.next(); // Skip first line
    if (lines.next()) |line| {
        return std.mem.indexOf(u8, line, ";") != null;
    }
    return false;
}

fn audioFileDuration(allocator: std.mem.Allocator, audio_file: []const u8) !f32 {
    const result = try runCommand(allocator, &.{
        "ffprobe", "-i",    audio_file, "-show_entries", "format=duration",
        "-v",      "quiet", "-of",      "csv=p=0",
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const trimmed = std.mem.trim(u8, result.stdout, " \t\n\r");
    return try std.fmt.parseFloat(f32, trimmed);
}

fn withConvertedAudio(allocator: std.mem.Allocator, config: *const Config, audio_file: []const u8, context: anytype, func: fn (allocator: std.mem.Allocator, config: *const Config, temp_path: []const u8, ctx: @TypeOf(context)) anyerror!void) !void {
    const temp_dir = std.testing.tmpDir(.{});
    const temp_path = try std.fmt.allocPrint(allocator, "{s}/olaf_audio_{d}.raw", .{ temp_dir.sub_path, std.time.milliTimestamp() });
    defer allocator.free(temp_path);
    defer fs.cwd().deleteFile(temp_path) catch {};

    const sample_rate_str = try std.fmt.allocPrint(allocator, "{d}", .{config.target_sample_rate});
    defer allocator.free(sample_rate_str);

    const result = try runCommand(allocator, &.{
        "ffmpeg",    "-hide_banner", "-y",  "-loglevel",     "panic", "-i",    audio_file,
        "-ac",       "1",            "-ar", sample_rate_str, "-f",    "f32le", "-acodec",
        "pcm_f32le", temp_path,
    });
    allocator.free(result.stdout);
    allocator.free(result.stderr);

    const basename = std.fs.path.basename(audio_file);
    print("Processing: {s}\n", .{basename});

    try func(allocator, config, temp_path, context);
}

fn withConvertedAudioPart(allocator: std.mem.Allocator, config: *const Config, audio_file: []const u8, start: f32, duration: f32, context: anytype, func: fn (allocator: std.mem.Allocator, config: *const Config, temp_path: []const u8, ctx: @TypeOf(context)) anyerror!void) !void {
    const temp_dir = std.testing.tmpDir(.{});
    const temp_path = try std.fmt.allocPrint(allocator, "{s}/olaf_audio_{d}.raw", .{ temp_dir.sub_path, std.time.milliTimestamp() });
    defer allocator.free(temp_path);
    defer fs.cwd().deleteFile(temp_path) catch {};

    const sample_rate_str = try std.fmt.allocPrint(allocator, "{d}", .{config.target_sample_rate});
    defer allocator.free(sample_rate_str);
    const start_str = try std.fmt.allocPrint(allocator, "{d:.2}", .{start});
    defer allocator.free(start_str);
    const duration_str = try std.fmt.allocPrint(allocator, "{d:.2}", .{duration});
    defer allocator.free(duration_str);

    const result = try runCommand(allocator, &.{
        "ffmpeg",    "-hide_banner", "-y",  "-loglevel", "panic", "-ss",           start_str, "-i",    audio_file,
        "-t",        duration_str,   "-ac", "1",         "-ar",   sample_rate_str, "-f",      "f32le", "-acodec",
        "pcm_f32le", temp_path,
    });
    allocator.free(result.stdout);
    allocator.free(result.stderr);

    try func(allocator, config, temp_path, context);
}

// Command implementations
fn cmdStats(allocator: std.mem.Allocator, config: *const Config, args: *Args) !void {
    _ = args;
    const result = try runCommand(allocator, &.{ config.executable_location, "stats" });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    print("{s}", .{result.stdout});
}

const StoreContext = struct {
    index: usize,
    total: usize,
    audio_file: []const u8,
};

fn storeCallback(allocator: std.mem.Allocator, config: *const Config, temp_path: []const u8, context: StoreContext) !void {
    const result = try runCommand(allocator, &.{ config.executable_location, "store", temp_path, context.audio_file });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const basename = std.fs.path.basename(context.audio_file);
    const stderr_trimmed = std.mem.trim(u8, result.stderr, " \t\n\r");
    print("{d}/{d} {s} {s}\n", .{ context.index, context.total, basename, stderr_trimmed });
}

fn cmdStore(allocator: std.mem.Allocator, config: *const Config, args: *Args) !void {
    for (args.audio_files.items, 0..) |audio_file, i| {
        if (config.check_incoming_audio) {
            const duration = audioFileDuration(allocator, audio_file) catch 0;
            if (duration == 0) {
                const basename = std.fs.path.basename(audio_file);
                print("{d}/{d} {s} INVALID audio file? Duration zero.\n", .{ i + 1, args.audio_files.items.len, basename });
                continue;
            }
        }

        if (config.skip_duplicates and try has(allocator, config, audio_file)) {
            const basename = std.fs.path.basename(audio_file);
            print("{d}/{d} {s} SKIP: already stored audio\n", .{ i + 1, args.audio_files.items.len, basename });
            continue;
        }

        const ctx = StoreContext{
            .index = i + 1,
            .total = args.audio_files.items.len,
            .audio_file = audio_file,
        };
        try withConvertedAudio(allocator, config, audio_file, ctx, storeCallback);
    }
}

const QueryContext = struct {
    index: usize,
    total: usize,
    audio_file: []const u8,
    allow_identity_match: bool,
};

fn queryCallback(allocator: std.mem.Allocator, config: *const Config, temp_path: []const u8, context: QueryContext) !void {
    const id_result = try runCommand(allocator, &.{ config.executable_location, "name_to_id", context.audio_file });
    defer {
        allocator.free(id_result.stdout);
        allocator.free(id_result.stderr);
    }
    const query_audio_id = try std.fmt.parseInt(u32, std.mem.trim(u8, id_result.stdout, " \t\n\r"), 10);

    const result = try runCommand(allocator, &.{ config.executable_location, "query", temp_path, context.audio_file });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const basename = std.fs.path.basename(context.audio_file);
    var lines = std.mem.tokenizeAny(u8, result.stdout, "\n");
    while (lines.next()) |line| {
        const parsed = try OlafResultLine.parse(allocator, line);
        if (!parsed.valid) continue;

        if (!context.allow_identity_match and query_audio_id == parsed.match_count) {
            continue;
        }

        print("{d}, {d}, {s}, 0, {s}\n", .{ context.index, context.total, basename, line });
    }

    if (result.stderr.len > 0) {
        std.debug.print("{s}\n", .{result.stderr});
    }
}

fn cmdQuery(allocator: std.mem.Allocator, config: *const Config, args: *Args) !void {
    if (args.threads > 1) {
        // TODO: Implement parallel processing
        print("Parallel processing not yet implemented. Using single thread.\n", .{});
    }

    for (args.audio_files.items, 0..) |audio_file, i| {
        if (args.fragmented) {
            try queryFragmented(allocator, config, i + 1, args.audio_files.items.len, audio_file, !args.allow_identity_match);
        } else {
            const ctx = QueryContext{
                .index = i + 1,
                .total = args.audio_files.items.len,
                .audio_file = audio_file,
                .allow_identity_match = args.allow_identity_match,
            };
            try withConvertedAudio(allocator, config, audio_file, ctx, queryCallback);
        }
    }
}

const FragmentContext = struct {
    query_audio_id: u32,
    ignore_self_match: bool,
    index: usize,
    total: usize,
    audio_file: []const u8,
    start: f32,
};

fn queryFragmentCallback(allocator: std.mem.Allocator, config: *const Config, temp_path: []const u8, context: FragmentContext) !void {
    const result = try runCommand(allocator, &.{ config.executable_location, "query", temp_path, context.audio_file });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const basename = std.fs.path.basename(context.audio_file);
    var lines = std.mem.tokenizeAny(u8, result.stdout, "\n");
    while (lines.next()) |line| {
        const parsed = try OlafResultLine.parse(allocator, line);
        if (!parsed.valid) continue;

        if (context.ignore_self_match and context.query_audio_id == parsed.match_count) {
            continue;
        }

        print("{d}, {d}, {s}, {d:.2}, {s}\n", .{ context.index, context.total, basename, context.start, line });
    }
}

fn queryFragmented(allocator: std.mem.Allocator, config: *const Config, index: usize, total: usize, audio_file: []const u8, ignore_self_match: bool) !void {
    const id_result = try runCommand(allocator, &.{ config.executable_location, "name_to_id", audio_file });
    defer {
        allocator.free(id_result.stdout);
        allocator.free(id_result.stderr);
    }
    const query_audio_id = try std.fmt.parseInt(u32, std.mem.trim(u8, id_result.stdout, " \t\n\r"), 10);

    const duration = try audioFileDuration(allocator, audio_file);
    var start: f32 = 0;
    const skip_size = @as(f32, @floatFromInt(config.fragment_duration_in_seconds));

    while (start + skip_size < duration) {
        const ctx = FragmentContext{
            .query_audio_id = query_audio_id,
            .ignore_self_match = ignore_self_match,
            .index = index,
            .total = total,
            .audio_file = audio_file,
            .start = start,
        };

        try withConvertedAudioPart(allocator, config, audio_file, start, skip_size, ctx, queryFragmentCallback);

        start += skip_size;
    }
}

fn cmdMic(allocator: std.mem.Allocator, config: *const Config, args: *Args) !void {
    _ = args;
    const sample_rate_str = try std.fmt.allocPrint(allocator, "{d}", .{config.target_sample_rate});
    defer allocator.free(sample_rate_str);

    print("ffmpeg -hide_banner -loglevel panic -f avfoundation -i none:default -ac 1 -ar {s} -f f32le -acodec pcm_f32le pipe:1 | {s} query\n", .{ sample_rate_str, config.executable_location });

    // This would need platform-specific implementation
    print("Microphone input not yet implemented in Zig wrapper\n", .{});
}

fn cmdClear(allocator: std.mem.Allocator, config: *const Config, args: *Args) !void {
    const db_path = try expandPath(allocator, config.db_folder);
    defer allocator.free(db_path);
    const cache_path = try expandPath(allocator, config.cache_folder);
    defer allocator.free(cache_path);

    var delete_db = args.force;
    var delete_cache = args.force;

    if (!args.force) {
        const db_size = folderSize(db_path) catch 0;
        print("Proceed with deleting the olaf db ({d:.0} MB {s})? (yes/no)\n", .{ db_size, db_path });

        const stdin = std.io.getStdIn().reader();
        var buf: [100]u8 = undefined;
        if (try stdin.readUntilDelimiterOrEof(&buf, '\n')) |input| {
            const trimmed = std.mem.trim(u8, input, " \t\n\r");
            if (std.mem.eql(u8, trimmed, "yes")) {
                delete_db = true;
            } else {
                print("Nothing deleted\n", .{});
            }
        }

        const cache_size = folderSize(cache_path) catch 0;
        print("Proceed with deleting the olaf cache ({d:.0} MB {s})? (yes/no)\n", .{ cache_size, cache_path });

        if (try stdin.readUntilDelimiterOrEof(&buf, '\n')) |input| {
            const trimmed = std.mem.trim(u8, input, " \t\n\r");
            if (std.mem.eql(u8, trimmed, "yes")) {
                delete_cache = true;
            } else {
                print("Operation cancelled.\n", .{});
            }
        }
    }

    if (delete_db) {
        print("Clear the database folder.\n", .{});
        var dir = fs.cwd().openDir(db_path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer dir.close();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            try dir.deleteFile(entry.name);
        }
    }

    if (delete_cache) {
        print("Clear the cache folder\n", .{});
        var dir = fs.cwd().openDir(cache_path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer dir.close();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            try dir.deleteFile(entry.name);
        }
    }
}

fn cmdDedup(allocator: std.mem.Allocator, config: *const Config, args: *Args) !void {
    // First store all files
    if (!args.skip_store) {
        for (args.audio_files.items, 0..) |audio_file, i| {
            const ctx = StoreContext{
                .index = i + 1,
                .total = args.audio_files.items.len,
                .audio_file = audio_file,
            };
            try withConvertedAudio(allocator, config, audio_file, ctx, storeCallback);
        }
    }

    // Then query with identity match disabled
    const saved_allow = args.allow_identity_match;
    args.allow_identity_match = false;
    defer args.allow_identity_match = saved_allow;

    try cmdQuery(allocator, config, args);
}

const DeleteContext = struct {
    index: usize,
    total: usize,
    audio_file: []const u8,
};

fn deleteCallback(allocator: std.mem.Allocator, config: *const Config, temp_path: []const u8, context: DeleteContext) !void {
    const result = try runCommand(allocator, &.{ config.executable_location, "delete", temp_path, context.audio_file });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const basename = std.fs.path.basename(context.audio_file);
    const stderr_trimmed = std.mem.trim(u8, result.stderr, " \t\n\r");
    print("{d}/{d} {s} {s}\n", .{ context.index, context.total, basename, stderr_trimmed });
}

fn cmdDelete(allocator: std.mem.Allocator, config: *const Config, args: *Args) !void {
    for (args.audio_files.items, 0..) |audio_file, i| {
        const ctx = DeleteContext{
            .index = i + 1,
            .total = args.audio_files.items.len,
            .audio_file = audio_file,
        };
        try withConvertedAudio(allocator, config, audio_file, ctx, deleteCallback);
    }
}

const PrintContext = struct {
    index: usize,
    total: usize,
    audio_file: []const u8,
};

fn printCallback(allocator: std.mem.Allocator, config: *const Config, temp_path: []const u8, context: PrintContext) !void {
    const result = try runCommand(allocator, &.{ config.executable_location, "print", temp_path, context.audio_file });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const expanded = try expandPath(allocator, context.audio_file);

    print("Audio file: {s}\n", .{expanded});

    defer allocator.free(expanded);

    var lines = std.mem.tokenizeAny(u8, result.stdout, "\n");
    while (lines.next()) |line| {
        print("{d}/{d},{s},{s}\n", .{ context.index, context.total, expanded, line });
    }
}

fn cmdPrint(allocator: std.mem.Allocator, config: *const Config, args: *Args) !void {
    for (args.audio_files.items, 0..) |audio_file, i| {
        const ctx = PrintContext{
            .index = i + 1,
            .total = args.audio_files.items.len,
            .audio_file = audio_file,
        };
        try withConvertedAudio(allocator, config, audio_file, ctx, printCallback);
    }
}

fn cmdCache(allocator: std.mem.Allocator, config: *const Config, args: *Args) !void {
    if (args.threads == 1) {
        print("Warning: only using a single thread. Speed up with e.g. with --threads 8\n", .{});
    }

    // TODO: Implement parallel processing
    for (args.audio_files.items, 0..) |audio_file, i| {
        const ctx = CacheContext{
            .index = i + 1,
            .total = args.audio_files.items.len,
            .audio_file = audio_file,
        };
        try withConvertedAudio(allocator, config, audio_file, ctx, cacheCallback);
    }
}

fn cmdStoreCached(allocator: std.mem.Allocator, config: *const Config, args: *Args) !void {
    _ = args;
    const cache_path = try expandPath(allocator, config.cache_folder);
    defer allocator.free(cache_path);

    var dir = try fs.cwd().openDir(cache_path, .{ .iterate = true });
    defer dir.close();

    var cached_files = std.ArrayList([]const u8).init(allocator);
    defer {
        for (cached_files.items) |item| {
            allocator.free(item);
        }
        cached_files.deinit();
    }

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, "tdb")) {
            const full_path = try fs.path.join(allocator, &.{ cache_path, entry.name });
            try cached_files.append(full_path);
        }
    }

    // Sort the files
    std.mem.sort([]const u8, cached_files.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    for (cached_files.items, 0..) |cache_file, i| {
        var audio_filename: ?[]const u8 = null;
        defer if (audio_filename) |af| allocator.free(af);

        // Try to read the first line to get the audio filename
        const file = fs.cwd().openFile(cache_file, .{}) catch |err| {
            print("{d}/{d} WARNING: {s} could not be opened: {}\n", .{ i + 1, cached_files.items.len, cache_file, err });
            continue;
        };
        defer file.close();

        const reader = file.reader();
        var buf: [4096]u8 = undefined;
        if (try reader.readUntilDelimiterOrEof(&buf, '\n')) |line| {
            var parts = std.mem.tokenizeScalar(u8, line, ',');
            _ = parts.next(); // Skip index/length
            if (parts.next()) |filename| {
                audio_filename = try allocator.dupe(u8, std.mem.trim(u8, filename, " \t"));
            }
        }

        if (audio_filename == null) {
            print("{d}/{d} No audio filename found in {s}. Format incorrect?\n", .{ i + 1, cached_files.items.len, cache_file });
            continue;
        }

        if (config.skip_duplicates and try has(allocator, config, audio_filename.?)) {
            const basename = std.fs.path.basename(audio_filename.?);
            print("{d}/{d} {s} SKIPPED: already indexed audio file\n", .{ i + 1, cached_files.items.len, basename });
        } else {
            const result = try runCommand(allocator, &.{ config.executable_location, "store_cached", cache_file });
            defer {
                allocator.free(result.stdout);
                allocator.free(result.stderr);
            }
            const basename = std.fs.path.basename(audio_filename.?);
            const stdout_trimmed = std.mem.trim(u8, result.stdout, " \t\n\r");
            print("{d}/{d} {s} {s}\n", .{ i + 1, cached_files.items.len, basename, stdout_trimmed });
        }
    }
}

fn cmdToRaw(allocator: std.mem.Allocator, config: *const Config, args: *Args) !void {
    // TODO: Implement parallel processing when threads > 1
    for (args.audio_files.items) |audio_file| {
        const full_basename = std.fs.path.basename(audio_file);
        const ext_start = std.mem.lastIndexOf(u8, full_basename, ".");
        const basename = if (ext_start) |idx| full_basename[0..idx] else full_basename;
        const raw_filename = try std.fmt.allocPrint(allocator, "olaf_audio_{s}.raw", .{basename});
        defer allocator.free(raw_filename);

        // Check if file already exists
        if (fs.cwd().statFile(raw_filename)) |_| {
            continue;
        } else |_| {}

        const Context = struct {
            index: usize,
            total: usize,
            audio_file: []const u8,
            raw_filename: []const u8,
        };

        const callback = struct {
            fn cb(alloc: std.mem.Allocator, cfg: *const Config, temp_path: []const u8, context: Context) !void {
                _ = cfg;
                _ = alloc;
                try fs.cwd().copyFile(temp_path, fs.cwd(), context.raw_filename, .{});
                const basenameaudio = std.fs.path.basename(context.audio_file);
                print("{d}/{d},{s},{s}\n", .{ context.index, context.total, basenameaudio, context.raw_filename });
            }
        }.cb;

        const ctx = Context{
            .index = 1,
            .total = args.audio_files.items.len,
            .audio_file = audio_file,
            .raw_filename = raw_filename,
        };

        try withConvertedAudio(allocator, config, audio_file, ctx, callback);
    }
}

fn cmdToWav(allocator: std.mem.Allocator, config: *const Config, args: *Args) !void {
    // TODO: Implement parallel processing when threads > 1
    for (args.audio_files.items, 0..) |raw_file, i| {
        const full_basename = std.fs.path.basename(raw_file);
        const ext_start = std.mem.lastIndexOf(u8, full_basename, ".");
        const basename = if (ext_start) |idx| full_basename[0..idx] else full_basename;

        const wav_filename = try std.fmt.allocPrint(allocator, "{s}.wav", .{basename});
        defer allocator.free(wav_filename);

        // Check if file already exists
        if (fs.cwd().statFile(wav_filename)) |_| {
            continue;
        } else |_| {}

        const sample_rate_str = try std.fmt.allocPrint(allocator, "{d}", .{config.target_sample_rate});
        defer allocator.free(sample_rate_str);

        const result = try runCommand(allocator, &.{
            "ffmpeg",     "-hide_banner", "-y",        "-loglevel",     "panic",
            "-ac",        "1",            "-ar",       sample_rate_str, "-f",
            "f32le",      "-acodec",      "pcm_f32le", "-i",            raw_file,
            wav_filename,
        });
        allocator.free(result.stdout);
        allocator.free(result.stderr);

        const raw_basename = std.fs.path.basename(raw_file);
        print("{d}/{d},{s},{s}\n", .{ i + 1, args.audio_files.items.len, raw_basename, wav_filename });
    }
}

const CacheContext = struct {
    index: usize,
    total: usize,
    audio_file: []const u8,
};

fn cacheCallback(allocator: std.mem.Allocator, config: *const Config, temp_path: []const u8, context: CacheContext) !void {
    const id_result = try runCommand(allocator, &.{ config.executable_location, "name_to_id", context.audio_file });
    defer {
        allocator.free(id_result.stdout);
        allocator.free(id_result.stderr);
    }

    const audio_id = std.mem.trim(u8, id_result.stdout, " \t\n\r");
    const cache_path = try expandPath(allocator, config.cache_folder);
    defer allocator.free(cache_path);

    const cache_file_name = try std.fmt.allocPrint(allocator, "{s}/{s}.tdb", .{ cache_path, audio_id });
    defer allocator.free(cache_file_name);

    // Check if cache file already exists
    if (fs.cwd().statFile(cache_file_name)) |_| {
        const basename = std.fs.path.basename(context.audio_file);
        print("{d}/{d},{s},{s}, SKIPPED: cache file already present\n", .{ context.index, context.total, basename, cache_file_name });
        return;
    } else |_| {}

    if (config.skip_duplicates and try has(allocator, config, context.audio_file)) {
        const basename = std.fs.path.basename(context.audio_file);
        print("{d}/{d} {s} SKIPPED: already indexed audio file\n", .{ context.index, context.total, basename });
        return;
    }

    // Run print command and write to cache file
    const result = try runCommand(allocator, &.{ config.executable_location, "print", temp_path, context.audio_file });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const expanded = try expandPath(allocator, context.audio_file);
    defer allocator.free(expanded);

    const file = try fs.cwd().createFile(cache_file_name, .{});
    defer file.close();

    var fp_counter: u32 = 0;
    var lines = std.mem.tokenizeScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        try file.writer().print("{d}/{d},{s},{s}\n", .{ context.index, context.total, expanded, line });
        fp_counter += 1;
    }

    const basename = std.fs.path.basename(context.audio_file);
    const stderr_trimmed = std.mem.trim(u8, result.stderr, " \t\n\r");
    print("{d}/{d} , {s} , {s} , {d} , {s}\n", .{ context.index, context.total, basename, cache_file_name, fp_counter, stderr_trimmed });
}

const commands = [_]Command{
    .{
        .name = "stats",
        .description = "Print statistics about the index.",
        .help = "",
        .needs_audio_files = false,
        .func = cmdStats,
    },
    .{
        .name = "store",
        .description = "Extracts and stores fingerprints into an index.",
        .help = "audio_files...",
        .needs_audio_files = true,
        .func = cmdStore,
    },
    .{
        .name = "to_raw",
        .description = "Converts audio to the RAW format olaf understands. Mainly for debugging.\n\t--threads n\t The number of threads to use.",
        .help = "[--threads n] audio_files...",
        .needs_audio_files = true,
        .func = cmdToRaw,
    },
    .{
        .name = "to_wav",
        .description = "Converts audio from the RAW format olaf understands to wav.\n\t--threads n\t The number of threads to use.",
        .help = "[--threads n] audio_files...",
        .needs_audio_files = true,
        .func = cmdToWav,
    },
    .{
        .name = "mic",
        .description = "Captures audio from the microphone and matches incoming audio with the index.",
        .help = "",
        .needs_audio_files = false,
        .func = cmdMic,
    },
    .{
        .name = "delete",
        .description = "Deletes audio files from the index.",
        .help = "audio_files...",
        .needs_audio_files = true,
        .func = cmdDelete,
    },
    .{
        .name = "print",
        .description = "Print fingerprint info to STDOUT.",
        .help = "audio_files...",
        .needs_audio_files = true,
        .func = cmdPrint,
    },
    .{
        .name = "query",
        .description = "Extracts fingerprints from audio, matches them with the index and report matches.\n\t\t--threads n\t The number of threads to use.\n\t\t--fragmented\t If present it does not match the full query all at once\n\t\t\tbut chops the query into 30s fragments and matches each fragment.\n\t\t--no-identity-match n\t If present identiy matches are not reported:\n\t\t\twhen a query is present in the index and it matches with itself it is not reported.",
        .help = "[--fragmented] [--threads x] audio_files...",
        .needs_audio_files = true,
        .func = cmdQuery,
    },
    .{
        .name = "cache",
        .description = "Extracts fingerprints and caches the fingerprints in a text file.\n\tThis is used to speed up fingerprint extraction by using multiple CPU cores.\n\t\t--threads n\t The number of threads to use.",
        .help = "[--threads x] audio_files...",
        .needs_audio_files = true,
        .func = cmdCache,
    },
    .{
        .name = "store_cached",
        .description = "Stores fingerprint cached in text files.\n\tAfter caching fingerprints in text files (on multiple cores) with 'olaf cache audio_files...' use store_cached\n\tto index the fingerprints in a datastore",
        .help = "",
        .needs_audio_files = false,
        .func = cmdStoreCached,
    },
    .{
        .name = "dedup",
        .description = "Deduplicates audio files: First all files are stored in the index.\n\tThen all files are matched with the index.\n\tIdentity matches are not reported.\n\t\t--threads n\t The number of threads to use.\n\t\t--fragmented\t If present it does not match the full query all at once\n\t\t\tbut chops the query into 30s fragments and matches each fragment.\n\t\t--skip-store\t Use this to skip storing the audio files\n\t\t and skip checking whether audio files are indexed.",
        .help = "[--fragmented] [--threads x] audio_files...",
        .needs_audio_files = true,
        .func = cmdDedup,
    },
    .{
        .name = "clear",
        .description = "Deletes the database and cached files.\n\t -f to delete without confirmation.",
        .help = "[-f]",
        .needs_audio_files = false,
        .func = cmdClear,
    },
};

fn printHelp(exe_path: []const u8) !void {
    // Get file modification time for version
    const stat = try fs.cwd().statFile(exe_path);
    const mtime_ns = @as(u64, @intCast(stat.mtime));
    const mtime_s = @divTrunc(mtime_ns, 1_000_000_000);
    const epoch_seconds = @as(i64, @intCast(mtime_s));

    // Convert to date components (simplified)
    const days_since_epoch = @divTrunc(epoch_seconds, 86400);
    const year = 1970 + @divTrunc(days_since_epoch, 365);
    const remaining_days = @mod(days_since_epoch, 365);
    const month = @divTrunc(remaining_days, 30) + 1;
    const day = @mod(remaining_days, 30) + 1;

    print("Olaf {d}.{d:0>2}.{d:0>2} - Overly Lightweight Audio Fingerprinting\n", .{ year, month, day });
    print("No such command, the following commands are valid:\n", .{});

    for (commands) |cmd| {
        print("\n{s}\t{s}\n", .{ cmd.name, cmd.description });
        print("\tolaf {s} {s}\n", .{ cmd.name, cmd.help });
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args_list = try process.argsAlloc(allocator);
    defer process.argsFree(allocator, args_list);

    if (args_list.len < 2) {
        try printHelp(args_list[0]);
        return;
    }

    const config = try loadConfig(allocator);

    // Create directories if they don't exist
    const db_path = try expandPath(allocator, config.db_folder);
    defer allocator.free(db_path);
    const cache_path = try expandPath(allocator, config.cache_folder);
    defer allocator.free(cache_path);

    fs.cwd().makePath(db_path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
    fs.cwd().makePath(cache_path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    const command_name = args_list[1];

    // Parse arguments
    var args = Args{
        .audio_files = std.ArrayList([]const u8).init(allocator),
    };
    defer {
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
            try audioFileList(allocator, arg, &args.audio_files, &config);
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
