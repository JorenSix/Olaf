const std = @import("std");
const process = std.process;
const debug = std.log.scoped(.olaf_wrapper).debug;

const olaf = @cImport({
    @cInclude("olaf_wrapper_bridge.h");
});

pub fn olaf_stats() !void {
    _ = olaf.olaf_stats();
    debug("olaf stats", .{});
}

pub fn olaf_main_wrapped_with_args(allocator: std.mem.Allocator, args_list: []const []const u8) !void {
    var c_argv = try allocator.alloc([*c]const u8, args_list.len);
    defer allocator.free(c_argv);

    for (args_list, 0..) |arg, i| {
        c_argv[i] = arg.ptr;
    }

    _ = olaf.olaf_main(@intCast(args_list.len), c_argv.ptr);
    debug("olaf main with custom args\n", .{});
}

pub fn olaf_store_using_wrapper() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = [_][]const u8{
        "olaf", // program name
        "store", // command
        "output.raw", // input file
        "input.mp3", // input file name full path original
    };

    try olaf_main_wrapped_with_args(allocator, &args);
}
