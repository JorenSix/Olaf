const std = @import("std");

pub fn build(b: *std.Build) void {
    const cflags = [_][]const u8{ "-Wall", "-Wextra", "-Werror=return-type", "-std=gnu11", "-O2" };

    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "olaf_wrapper",
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("olaf_wrapper.zig"),
    });

    exe.addCSourceFile(.{ .file = b.path("../src/hash-table.c"), .flags = &cflags });
    exe.addCSourceFile(.{ .file = b.path("../src/mdb.c"), .flags = &cflags });
    exe.addCSourceFile(.{ .file = b.path("../src/midl.c"), .flags = &cflags });
    exe.addCSourceFile(.{ .file = b.path("../src/pffft.c"), .flags = &cflags });
    exe.addCSourceFile(.{ .file = b.path("../src/queue.c"), .flags = &cflags });
    exe.addCSourceFile(.{ .file = b.path("../src/olaf_deque.c"), .flags = &cflags });
    exe.addCSourceFile(.{ .file = b.path("../src/olaf_max_filter_perceptual_van_herk.c"), .flags = &cflags });
    exe.addCSourceFile(.{ .file = b.path("./olaf_wrapper_bridge.c"), .flags = &cflags });
    exe.addCSourceFile(.{ .file = b.path("../src/olaf_config.c"), .flags = &cflags });
    exe.addCSourceFile(.{ .file = b.path("../src/olaf_db.c"), .flags = &cflags });
    exe.addCSourceFile(.{ .file = b.path("../src/olaf_ep_extractor.c"), .flags = &cflags });
    exe.addCSourceFile(.{ .file = b.path("../src/olaf_fp_db_writer.c"), .flags = &cflags });
    exe.addCSourceFile(.{ .file = b.path("../src/olaf_fp_db_writer_cache.c"), .flags = &cflags });
    exe.addCSourceFile(.{ .file = b.path("../src/olaf_fp_extractor.c"), .flags = &cflags });
    exe.addCSourceFile(.{ .file = b.path("../src/olaf_fp_matcher.c"), .flags = &cflags });
    exe.addCSourceFile(.{ .file = b.path("../src/olaf_reader_stream.c"), .flags = &cflags });
    exe.addCSourceFile(.{ .file = b.path("../src/olaf_runner.c"), .flags = &cflags });
    exe.addCSourceFile(.{ .file = b.path("../src/olaf_stream_processor.c"), .flags = &cflags });

    exe.addIncludePath(b.path("../src"));

    exe.linkLibC();

    b.installArtifact(exe);

    const run_step = b.addRunArtifact(exe);
    b.step("run", "Run the application").dependOn(&run_step.step);
}
