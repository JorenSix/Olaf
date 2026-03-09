const std = @import("std");
const fs = std.fs;
const http = std.http;

const REF_URL = "https://0110.be/releases/Panako/Panako-test-dataset/reference/";
const REF_FILES = [_][]const u8{
    "1051039.mp3",
    "1071559.mp3",
    "1075784.mp3",
    "11266.mp3",
    "147199.mp3",
    "173050.mp3",
    "189211.mp3",
    "297888.mp3",
    "612409.mp3",
    "852601.mp3",
};
const REF_TARGET_FOLDER = "dataset/ref";

const QUERY_URL = "https://0110.be/releases/Panako/Panako-test-dataset/queries/";
const QUERY_FILES = [_][]const u8{
    "1024035_55s-75s.mp3",
    "1051039_34s-54s.mp3",
    "1071559_60s-80s.mp3",
    "1075784_78s-98s.mp3",
    "11266_69s-89s.mp3",
    "132755_137s-157s.mp3",
    "147199_115s-135s.mp3",
    "173050_86s-106s.mp3",
    "189211_60s-80s.mp3",
    "295781_88s-108s.mp3",
    "297888_45s-65s.mp3",
    "361430_180s-200s.mp3",
    "371009_187s-207s.mp3",
    "378501_59s-79s.mp3",
    "384991_294s-314s.mp3",
    "432279_81s-101s.mp3",
    "43383_224s-244s.mp3",
    "478466_24s-44s.mp3",
    "602848_242s-262s.mp3",
    "604705_154s-174s.mp3",
    "612409_73s-93s.mp3",
    "824093_182s-202s.mp3",
    "84302_232s-252s.mp3",
    "852601_43s-63s.mp3",
    "96644_84s-104s.mp3",
};
const QUERY_TARGET_FOLDER = "dataset/queries";

const QUERY_OTA_URL = "https://0110.be/releases/Panako/Panako-test-dataset/queries_ota/";
const QUERY_OTA_FILES = [_][]const u8{
    "1024035_55s-75s_ota.mp3",
    "1051039_34s-54s_ota.mp3",
    "1071559_60s-80s_ota.mp3",
    "1075784_78s-98s_ota.mp3",
    "11266_69s-89s_ota.mp3",
    "132755_137s-157s_ota.mp3",
    "147199_115s-135s_ota.mp3",
    "173050_86s-106s_ota.mp3",
    "189211_60s-80s_ota.mp3",
    "295781_88s-108s_ota.mp3",
    "297888_45s-65s_ota.mp3",
    "361430_180s-200s_ota.mp3",
    "371009_187s-207s_ota.mp3",
    "378501_59s-79s_ota.mp3",
    "384991_294s-314s_ota.mp3",
    "432279_81s-101s_ota.mp3",
    "43383_224s-244s_ota.mp3",
    "478466_24s-44s_ota.mp3",
    "602848_242s-262s_ota.mp3",
    "604705_154s-174s_ota.mp3",
    "612409_73s-93s_ota.mp3",
    "824093_182s-202s_ota.mp3",
    "84302_232s-252s_ota.mp3",
    "852601_43s-63s_ota.mp3",
    "96644_84s-104s_ota.mp3",
};
const QUERY_OTA_TARGET_FOLDER = "dataset/queries_ota";

pub const DatasetKind = enum {
    ref_only,
    ref_and_queries,
    all, // includes OTA queries
};

/// Ensures the dataset files are downloaded and valid.
/// Skips files that are already cached locally.
pub fn ensureDataset(allocator: std.mem.Allocator, kind: DatasetKind) !void {
    var client = http.Client{ .allocator = allocator };
    defer client.deinit();

    try downloadFiles(allocator, &client, REF_URL, REF_TARGET_FOLDER, &REF_FILES);
    try checkFiles(REF_TARGET_FOLDER, 100 * 1024);

    if (kind == .ref_only) return;

    try downloadFiles(allocator, &client, QUERY_URL, QUERY_TARGET_FOLDER, &QUERY_FILES);
    try checkFiles(QUERY_TARGET_FOLDER, 100 * 1024);

    if (kind == .ref_and_queries) return;

    try downloadFiles(allocator, &client, QUERY_OTA_URL, QUERY_OTA_TARGET_FOLDER, &QUERY_OTA_FILES);
    try checkFiles(QUERY_OTA_TARGET_FOLDER, 50 * 1024);
}

fn downloadFiles(
    allocator: std.mem.Allocator,
    client: *http.Client,
    base_url: []const u8,
    target_folder: []const u8,
    files: []const []const u8,
) !void {
    fs.cwd().makePath(target_folder) catch {};

    for (files) |file| {
        const target = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ target_folder, file });
        defer allocator.free(target);

        // Skip if already cached
        if (fs.cwd().statFile(target)) |_| {
            std.debug.print("Found cached file {s}\n", .{target});
            continue;
        } else |_| {}

        const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ base_url, file });
        defer allocator.free(url);

        std.debug.print("Downloading {s}\n", .{target});
        try downloadFile(client, url, target);
        std.debug.print("Downloaded {s}\n", .{target});
    }
}

fn downloadFile(client: *http.Client, url: []const u8, target: []const u8) !void {
    var out_file = try fs.cwd().createFile(target, .{});
    defer out_file.close();

    var write_buf: [8192]u8 = undefined;
    var file_writer = out_file.writer(&write_buf);

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &file_writer.interface,
    });

    try file_writer.interface.flush();

    if (result.status != .ok) {
        std.debug.print("HTTP {d} for {s}\n", .{ @intFromEnum(result.status), url });
        return error.DownloadFailed;
    }
}

fn checkFiles(folder: []const u8, min_size: u64) !void {
    var dir = fs.cwd().openDir(folder, .{ .iterate = true }) catch |err| {
        std.debug.print("Cannot open {s}: {}\n", .{ folder, err });
        return error.DatasetCheckFailed;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".mp3")) continue;

        const stat = try dir.statFile(entry.name);
        if (stat.size < min_size) {
            std.debug.print("{s}/{s} too small: {d} bytes\n", .{ folder, entry.name, stat.size });
            return error.DatasetCheckFailed;
        }
    }
}
