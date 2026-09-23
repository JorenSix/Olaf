const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const helper = @import("db_test_options").helper;

fn run(args: []const []const u8, expected: u8) !void {
    return runAt(args, expected, .inherit);
}

fn runAt(args: []const []const u8, expected: u8, cwd: std.process.Child.Cwd) !void {
    const a = std.testing.allocator;
    var executable: [std.fs.max_path_bytes]u8 = undefined;
    const n = try Io.Dir.cwd().realPathFile(std.testing.io, args[0], &executable);
    const argv = try a.dupe([]const u8, args);
    defer a.free(argv);
    argv[0] = executable[0..n];
    const result = try std.process.run(a, std.testing.io, .{ .argv = argv, .cwd = cwd });
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    if (result.term != .exited or result.term.exited != expected) {
        std.debug.print("DB helper failed: {any}\n{s}\n{s}\n", .{ result.term, result.stdout, result.stderr });
        return error.UnexpectedExitStatus;
    }
}

test "shared environments, snapshots, aliases and concurrent lifetimes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "a", .default_dir);
    try tmp.dir.createDir(io, "b", .default_dir);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const a = std.testing.allocator;
    const path = try std.fmt.allocPrint(a, "{s}/a", .{buf[0..n]});
    defer a.free(path);
    const other = try std.fmt.allocPrint(a, "{s}/b", .{buf[0..n]});
    defer a.free(other);
    //Exercise a symlink alias where creating symlinks does not need privileges.
    if (builtin.os.tag != .windows) {
        try tmp.dir.symLink(io, "a", "alias", .{ .is_directory = true });
    }
    const alias = if (builtin.os.tag == .windows) "a/" else "alias/";
    try runAt(&.{ helper, "all", path, other, alias }, 0, .{ .path = buf[0..n] });
}

test "cross-process writer preserves reader snapshot" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const path = buf[0..n];
    try run(&.{ helper, "seed", path }, 0);
    var child = try std.process.spawn(io, .{
        .argv = &.{ helper, "reader", path },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    defer child.kill(io);
    var ready: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try child.stdout.?.readStreaming(io, &.{&ready}));
    try std.testing.expectEqual(@as(u8, 'R'), ready[0]);
    try run(&.{ helper, "replace", path }, 0);
    try child.stdin.?.writeStreamingAll(io, "C");
    const term = try child.wait(io);
    try std.testing.expect(term == .exited and term.exited == 0);
}

test "readonly open does not create a missing database" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    try run(&.{ helper, "missing", buf[0..n] }, 214);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "data.mdb", .{}));
}
