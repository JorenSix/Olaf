const std = @import("std");

pub fn build(b: *std.Build) void {
    const cflags = [_][]const u8{ "-Wall", "-Wextra", "-Werror=return-type", "-std=gnu11", "-O2", "-fPIC" };

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const build_core = b.option(bool, "core", "Build the Olaf core and not the CLI interface  (default: false)") orelse false;

    if (target.result.cpu.arch == .wasm32) {
        const lib = b.addExecutable(.{
            .name = "olaf_c",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
            }),
        });

        addCoreSources(lib, b, &cflags, false, false, false); // false = no LMDB sources
        lib.linkLibC();
        b.installArtifact(lib);
    } else {

        // if only build core c library olaf_c for linking from other languages
        if (build_core) {
            const exe = b.addExecutable(.{
                .name = "olaf_c",
                .root_module = b.createModule(.{
                    .target = target,
                    .optimize = optimize,
                }),
            });

            addCoreSources(exe, b, &cflags, true, true, false);
            exe.linkLibC();
            b.installArtifact(exe);

            // run step
            const run_step = b.addRunArtifact(exe);
            run_step.setCwd(b.path(".")); // Set working directory to project root
            b.step("run", "Run Olaf core").dependOn(&run_step.step);

            if (b.args) |args| {
                run_step.addArgs(args);
            }
        } else {
            const exe = b.addExecutable(.{
                .name = "olaf",
                .root_module = b.createModule(.{
                    .target = target,
                    .optimize = optimize,
                    .root_source_file = b.path("./cli/olaf_wrapper.zig"),
                }),
            });
            exe.addIncludePath(b.path("cli"));
            exe.addIncludePath(b.path("src"));
            addCoreSources(exe, b, &cflags, true, false, true); // true = include LMDB sources
            exe.linkLibC();
            b.installArtifact(exe);

            // run step
            const run_step = b.addRunArtifact(exe);
            run_step.setCwd(b.path(".")); // Set working directory to project root
            b.step("run", "Run Olaf CLI").dependOn(&run_step.step);

            if (b.args) |args| {
                run_step.addArgs(args);
            }
        }
    }

    // install step
    // Custom install step to system location
    const install_system_step = b.step("install-system", "Install Olaf to standard system location with config files");
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
}

/// Add core Olaf C source files to an executable
fn addCoreSources(
    exe: *std.Build.Step.Compile,
    b: *std.Build,
    cflags: []const []const u8,
    include_lmdb: bool,
    include_olaf_main: bool,
    include_cli_wrapper: bool,
) void {
    // Common sources used by all builds
    const common_sources = [_][]const u8{
        "src/hash-table.c",
        "src/pffft.c",
        "src/queue.c",

        "src/olaf_deque.c",
        "src/olaf_max_filter_perceptual_van_herk.c",
        "src/olaf_config.c",
        "src/olaf_ep_extractor.c",
        "src/olaf_fp_db_writer.c",
        "src/olaf_fp_db_writer_cache.c",
        "src/olaf_fp_extractor.c",
        "src/olaf_fp_matcher.c",
        "src/olaf_reader_stream.c",
        "src/olaf_runner.c",
        "src/olaf_stream_processor.c",
    };

    // LMDB sources (only for native builds)
    const lmdb_sources = [_][]const u8{
        "src/mdb.c",
        "src/midl.c",
    };

    // Database implementation sources
    const db_sources = [_][]const u8{
        if (include_lmdb) "src/olaf_db.c" else "src/olaf_db_mem.c",
    };

    // Add all common sources
    for (common_sources) |src| {
        exe.addCSourceFile(.{ .file = b.path(src), .flags = cflags });
    }

    // Add LMDB sources if needed
    if (include_lmdb) {
        for (lmdb_sources) |src| {
            exe.addCSourceFile(.{ .file = b.path(src), .flags = cflags });
        }
    }

    // Add database sources
    for (db_sources) |src| {
        exe.addCSourceFile(.{ .file = b.path(src), .flags = cflags });
    }

    // Optionally add main executable source
    if (include_olaf_main) {
        exe.addCSourceFile(.{ .file = b.path("./src/olaf.c"), .flags = cflags });
    }

    // Optionally add wrapper bridge
    if (include_cli_wrapper) {
        exe.addCSourceFile(.{ .file = b.path("./cli/olaf_wrapper_bridge.c"), .flags = cflags });
    }
}
