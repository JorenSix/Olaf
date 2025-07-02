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

    if (target.result.cpu.arch == .wasm32) {
        const cflagslib = [_][]const u8{ "-Wall", "-Wextra", "-Werror=return-type", "-std=gnu11", "-O2", "-fPIC" };
        const lib = b.addExecutable(.{
            .name = "olaf_c",
            .target = target,
            .optimize = optimize,
        });
        
        lib.addCSourceFile(.{ .file = b.path("src/hash-table.c"), .flags = &cflagslib });
        lib.addCSourceFile(.{ .file = b.path("src/pffft.c"), .flags = &cflagslib });
        lib.addCSourceFile(.{ .file = b.path("src/queue.c"), .flags = &cflagslib });
        lib.addCSourceFile(.{ .file = b.path("src/olaf_deque.c"), .flags = &cflagslib });
        lib.addCSourceFile(.{ .file = b.path("src/olaf_max_filter_perceptual_van_herk.c"), .flags = &cflagslib });
        lib.addCSourceFile(.{ .file = b.path("src/olaf.c"), .flags = &cflagslib });
        lib.addCSourceFile(.{ .file = b.path("src/olaf_config.c"), .flags = &cflagslib });
        lib.addCSourceFile(.{ .file = b.path("src/olaf_db_mem.c"), .flags = &cflagslib });
        lib.addCSourceFile(.{ .file = b.path("src/olaf_ep_extractor.c"), .flags = &cflagslib });
        lib.addCSourceFile(.{ .file = b.path("src/olaf_fp_db_writer.c"), .flags = &cflagslib });
        lib.addCSourceFile(.{ .file = b.path("src/olaf_fp_db_writer_cache.c"), .flags = &cflagslib });
        lib.addCSourceFile(.{ .file = b.path("src/olaf_fp_extractor.c"), .flags = &cflagslib });
        lib.addCSourceFile(.{ .file = b.path("src/olaf_fp_matcher.c"), .flags = &cflagslib });
        lib.addCSourceFile(.{ .file = b.path("src/olaf_reader_stream.c"), .flags = &cflagslib });
        lib.addCSourceFile(.{ .file = b.path("src/olaf_runner.c"), .flags = &cflagslib });
        lib.addCSourceFile(.{ .file = b.path("src/olaf_stream_processor.c"), .flags = &cflagslib });
        lib.linkLibC();

        b.installArtifact(lib);
    } else {
        const exe = b.addExecutable(.{
            .name = "olaf_c",
            .target = target,
            .optimize = optimize,
        });

        exe.addCSourceFile(.{ .file = b.path("src/hash-table.c"), .flags = &cflags });
        exe.addCSourceFile(.{ .file = b.path("src/mdb.c"), .flags = &cflags });
        exe.addCSourceFile(.{ .file = b.path("src/midl.c"), .flags = &cflags });
        exe.addCSourceFile(.{ .file = b.path("src/pffft.c"), .flags = &cflags });
        exe.addCSourceFile(.{ .file = b.path("src/queue.c"), .flags = &cflags });
        exe.addCSourceFile(.{ .file = b.path("src/olaf_deque.c"), .flags = &cflags });
        exe.addCSourceFile(.{ .file = b.path("src/olaf_max_filter_perceptual_van_herk.c"), .flags = &cflags });
        exe.addCSourceFile(.{ .file = b.path("src/olaf.c"), .flags = &cflags });
        exe.addCSourceFile(.{ .file = b.path("src/olaf_config.c"), .flags = &cflags });
        exe.addCSourceFile(.{ .file = b.path("src/olaf_db.c"), .flags = &cflags });
        exe.addCSourceFile(.{ .file = b.path("src/olaf_ep_extractor.c"), .flags = &cflags });
        exe.addCSourceFile(.{ .file = b.path("src/olaf_fp_db_writer.c"), .flags = &cflags });
        exe.addCSourceFile(.{ .file = b.path("src/olaf_fp_db_writer_cache.c"), .flags = &cflags });
        exe.addCSourceFile(.{ .file = b.path("src/olaf_fp_extractor.c"), .flags = &cflags });
        exe.addCSourceFile(.{ .file = b.path("src/olaf_fp_matcher.c"), .flags = &cflags });
        exe.addCSourceFile(.{ .file = b.path("src/olaf_reader_stream.c"), .flags = &cflags });
        exe.addCSourceFile(.{ .file = b.path("src/olaf_runner.c"), .flags = &cflags });
        exe.addCSourceFile(.{ .file = b.path("src/olaf_stream_processor.c"), .flags = &cflags });
        exe.linkLibC();

        b.installArtifact(exe);
    }
}
