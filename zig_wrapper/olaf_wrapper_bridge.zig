const std = @import("std");
const process = std.process;
const debug = std.log.scoped(.olaf_wrapper).debug;

const olaf = @cImport({
    @cInclude("olaf_wrapper_bridge.h");
});

fn olaf_main(allocator: std.mem.Allocator, args_list: []const []const u8) !void {
    var c_argv = try allocator.alloc([*c]const u8, args_list.len);
    defer allocator.free(c_argv);
    for (args_list, 0..) |arg, i| {
        c_argv[i] = arg.ptr;
    }
    _ = olaf.olaf_main(@intCast(args_list.len), c_argv.ptr);
    debug("olaf main with custom args\n", .{});
}

pub fn olaf_store(allocator: std.mem.Allocator, input_raw: []const u8, input_path: []const u8) !void {
    const args = [_][]const u8{
        "olaf", // program name
        "store", // command
        input_raw, // input file
        input_path, // input file name full path original
    };

    try olaf_main(allocator, &args);
}

pub fn olaf_query(allocator: std.mem.Allocator, input_raw: []const u8, input_path: []const u8) !void {
    const args = [_][]const u8{
        "olaf", // program name
        "query", // command
        input_raw, // input file
        input_path, // input file name full path original
    };
    try olaf_main(allocator, &args);
}

pub fn olaf_stats(allocator: std.mem.Allocator) !void {
    const args = [_][]const u8{
        "olaf", // program name
        "stats", // command
    };

    try olaf_main(allocator, &args);
}
