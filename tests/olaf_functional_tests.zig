const std = @import("std");
const testing = std.testing;
const fs = std.fs;
const dataset = @import("dataset_download.zig");

// C imports for Olaf core
const c = @cImport({
    @cInclude("olaf_config.h");
    @cInclude("olaf_reader.h");
    @cInclude("olaf_db.h");
    @cInclude("olaf_deque.h");
});

// ============================================================================
// Dataset Download - Ensures test audio files are available
// ============================================================================

test "dataset: ensure reference and query files are downloaded" {
    try dataset.ensureDataset(testing.allocator, .ref_and_queries);
}

// ============================================================================
// Functional Tests - Testing CLI Commands
// ============================================================================

/// Helper to create a test database directory
fn createTestDbDir(allocator: std.mem.Allocator) ![]const u8 {
    const timestamp = std.time.timestamp();
    const test_db_path = try std.fmt.allocPrint(
        allocator,
        "tests/test_db_{d}",
        .{timestamp},
    );

    try fs.cwd().makePath(test_db_path);
    return test_db_path;
}

/// Helper to clean up test database directory
fn cleanupTestDbDir(path: []const u8) void {
    fs.cwd().deleteTree(path) catch |err| {
        std.debug.print("Warning: Failed to cleanup test directory {s}: {}\n", .{ path, err });
    };
}

test "functional: store and query audio" {
    // Check if ffmpeg is available
    const result = std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &[_][]const u8{ "ffmpeg", "-version" },
    }) catch {
        std.debug.print("\nSkipping functional test: ffmpeg not available\n", .{});
        return error.SkipZigTest;
    };
    testing.allocator.free(result.stdout);
    testing.allocator.free(result.stderr);

    // This is a skeleton - in a real implementation, you would:
    // 1. Create a test audio file or use an existing one
    // 2. Call olaf store command via the bridge
    // 3. Call olaf query command with the same file
    // 4. Verify match results

    std.debug.print("\nFunctional test skeleton - implement with real audio files\n", .{});
}

test "functional: config validation" {
    // Test that configuration can be loaded and validated
    const config = c.olaf_config_default();
    defer c.olaf_config_destroy(config);

    try testing.expect(config.*.audioSampleRate > 0);
    try testing.expect(config.*.audioBlockSize > 0);
    try testing.expect(config.*.audioStepSize > 0);
    try testing.expect(config.*.audioStepSize <= config.*.audioBlockSize);
}

// ============================================================================
// Integration Tests - Testing End-to-End Workflows
// ============================================================================

test "integration: fingerprint extraction pipeline" {
    // This is a skeleton for testing the full pipeline:
    // Audio Input → Reader → Stream Processor → EP Extractor → FP Extractor

    std.debug.print("\nIntegration test skeleton - implement full pipeline test\n", .{});
}

// ============================================================================
// Benchmark Tests - Performance Testing
// ============================================================================

test "benchmark: fingerprint extraction speed" {
    // Skip benchmark in debug mode
    if (@import("builtin").mode == .Debug) {
        std.debug.print("\nSkipping benchmark in debug mode\n", .{});
        return error.SkipZigTest;
    }

    // This is a skeleton for benchmarking fingerprint extraction
    std.debug.print("\nBenchmark test skeleton - implement timing tests\n", .{});
}

// ============================================================================
// Test Runner Utilities
// ============================================================================

/// Run all C unit tests by calling the compiled olaf_tests binary
pub fn runCUnitTests(allocator: std.mem.Allocator) !void {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{"bin/olaf_tests"},
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        std.debug.print("C unit tests failed:\n{s}\n", .{result.stderr});
        return error.CUnitTestsFailed;
    }

    std.debug.print("C unit tests passed:\n{s}\n", .{result.stdout});
}

/// Main test entry point - can be called from build.zig
pub fn runAllTests(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== Running Olaf Test Suite ===\n\n", .{});

    // Run C unit tests if binary exists
    std.debug.print("Running C unit tests...\n", .{});
    runCUnitTests(allocator) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("C unit tests not found - run 'make test' first\n", .{});
        } else {
            return err;
        }
    };

    std.debug.print("\nAll Zig unit tests are run automatically by 'zig build test'\n", .{});
}
