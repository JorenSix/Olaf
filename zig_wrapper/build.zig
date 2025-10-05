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
        .name = "olaf",
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
    exe.addIncludePath(b.path("."));

    exe.linkLibC();

    b.installArtifact(exe);

    // install step
    // Custom install step to system location
    const install_system_step = b.step("install-system", "Install olaf to system location with config files");

    const builtin = @import("builtin");
    const install_system_run = switch (builtin.os.tag) {
        .windows => b.addSystemCommand(&[_][]const u8{ "cmd", "/c", "copy zig-out\\bin\\olaf.exe olaf.exe\" && " ++
            "if not exist \"%USERPROFILE%\\.olaf\\db\" mkdir \"%USERPROFILE%\\.olaf\\db\" && " ++
            "if not exist \"%USERPROFILE%\\.olaf\\cache\" mkdir \"%USERPROFILE%\\.olaf\\cache\" " }),
        else => b.addSystemCommand(&[_][]const u8{ "sh", "-c", "sudo cp zig-out/bin/olaf /usr/local/bin/olaf && " ++
            "sudo cp olaf_config.json /usr/local/bin/olaf_config.json && " ++
            "sudo cp olaf_config.schema.json /usr/local/bin/olaf_config.schema.json && " ++
            "mkdir -p ~/.olaf/db ~/.olaf/cache" }),
    };
    install_system_run.step.dependOn(b.getInstallStep());
    install_system_step.dependOn(&install_system_run.step);

    // run step

    const run_step = b.addRunArtifact(exe);
    run_step.setCwd(b.path(".")); // Set working directory to project root
    b.step("run", "Run the application").dependOn(&run_step.step);

    if (b.args) |args| {
        run_step.addArgs(args);
    }
}
