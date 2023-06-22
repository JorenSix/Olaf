const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const cflags = [_][]const u8{ "-Wall", "-Wextra", "-Werror=return-type", "-std=gnu11", "-O2" };

    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    if (target.getCpuArch() == .wasm32) {
        const cflagslib = [_][]const u8{ "-Wall", "-Wextra", "-Werror=return-type", "-std=gnu11", "-O2", "-fPIC" };
        const lib = b.addExecutable("olaf_c", null);
        lib.addCSourceFile("src/hash-table.c", &cflagslib);
        lib.addCSourceFile("src/pffft.c", &cflagslib);
        lib.addCSourceFile("src/queue.c", &cflagslib);
        lib.addCSourceFile("src/olaf_deque.c", &cflagslib);
        lib.addCSourceFile("src/olaf_max_filter_perceptual_van_herk.c", &cflagslib);
        lib.addCSourceFile("src/olaf.c", &cflagslib);
        lib.addCSourceFile("src/olaf_config.c", &cflagslib);
        lib.addCSourceFile("src/olaf_db_mem.c", &cflagslib);
        lib.addCSourceFile("src/olaf_ep_extractor.c", &cflagslib);
        lib.addCSourceFile("src/olaf_fp_db_writer.c", &cflagslib);
        lib.addCSourceFile("src/olaf_fp_db_writer_cache.c", &cflagslib);
        lib.addCSourceFile("src/olaf_fp_extractor.c", &cflagslib);
        lib.addCSourceFile("src/olaf_fp_matcher.c", &cflagslib);
        lib.addCSourceFile("src/olaf_reader_stream.c", &cflagslib);
        lib.addCSourceFile("src/olaf_runner.c", &cflagslib);
        lib.addCSourceFile("src/olaf_stream_processor.c", &cflagslib);
        lib.linkLibC();

        lib.setTarget(target);
        lib.setBuildMode(mode);
        lib.install();
    } else {
        const exe = b.addExecutable("olaf_c", null);

        exe.addCSourceFile("src/hash-table.c", &cflags);
        exe.addCSourceFile("src/mdb.c", &cflags);
        exe.addCSourceFile("src/midl.c", &cflags);
        exe.addCSourceFile("src/pffft.c", &cflags);
        exe.addCSourceFile("src/queue.c", &cflags);
        exe.addCSourceFile("src/olaf_deque.c", &cflags);
        exe.addCSourceFile("src/olaf_max_filter_perceptual_van_herk.c", &cflags);
        exe.addCSourceFile("src/olaf.c", &cflags);
        exe.addCSourceFile("src/olaf_config.c", &cflags);
        exe.addCSourceFile("src/olaf_db.c", &cflags);
        exe.addCSourceFile("src/olaf_ep_extractor.c", &cflags);
        exe.addCSourceFile("src/olaf_fp_db_writer.c", &cflags);
        exe.addCSourceFile("src/olaf_fp_db_writer_cache.c", &cflags);
        exe.addCSourceFile("src/olaf_fp_extractor.c", &cflags);
        exe.addCSourceFile("src/olaf_fp_matcher.c", &cflags);
        exe.addCSourceFile("src/olaf_reader_stream.c", &cflags);
        exe.addCSourceFile("src/olaf_runner.c", &cflags);
        exe.addCSourceFile("src/olaf_stream_processor.c", &cflags);
        exe.linkLibC();

        exe.setTarget(target);
        exe.setBuildMode(mode);
        exe.install();
    }
}
