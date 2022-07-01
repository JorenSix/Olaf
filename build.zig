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

    const exe = b.addExecutable("olaf_c", null);

    if (target.getCpuArch() == .wasm32 and target.getOsTag() == .wasi) {
        exe.addCSourceFile("src/hash-table.c", &cflags);
        exe.addCSourceFile("src/pffft.c", &cflags);
        exe.addCSourceFile("src/olaf.c", &cflags);
        exe.addCSourceFile("src/olaf_config.c", &cflags);
        exe.addCSourceFile("src/olaf_db_mem.c", &cflags);
        exe.addCSourceFile("src/olaf_ep_extractor.c", &cflags);
        exe.addCSourceFile("src/olaf_fp_db_writer.c", &cflags);
        exe.addCSourceFile("src/olaf_fp_extractor.c", &cflags);
        exe.addCSourceFile("src/olaf_fp_matcher.c", &cflags);
        exe.addCSourceFile("src/olaf_reader_stream.c", &cflags);
        exe.addCSourceFile("src/olaf_runner.c", &cflags);
        exe.addCSourceFile("src/olaf_stream_processor.c", &cflags);
        exe.linkLibC();
    } else {
        exe.addCSourceFile("src/hash-table.c", &cflags);
        exe.addCSourceFile("src/mdb.c", &cflags);
        exe.addCSourceFile("src/midl.c", &cflags);
        exe.addCSourceFile("src/pffft.c", &cflags);
        exe.addCSourceFile("src/olaf.c", &cflags);
        exe.addCSourceFile("src/olaf_config.c", &cflags);
        exe.addCSourceFile("src/olaf_db.c", &cflags);
        exe.addCSourceFile("src/olaf_ep_extractor.c", &cflags);
        exe.addCSourceFile("src/olaf_fp_db_writer.c", &cflags);
        exe.addCSourceFile("src/olaf_fp_extractor.c", &cflags);
        exe.addCSourceFile("src/olaf_fp_matcher.c", &cflags);
        exe.addCSourceFile("src/olaf_reader_stream.c", &cflags);
        exe.addCSourceFile("src/olaf_runner.c", &cflags);
        exe.addCSourceFile("src/olaf_stream_processor.c", &cflags);
        exe.linkLibC();
    }

    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();
}
