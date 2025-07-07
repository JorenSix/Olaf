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

pub fn olaf_main_wrapped(allocator: std.mem.Allocator) !void {
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
