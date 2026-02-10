const std = @import("std");
const testing = std.testing;
const fs = std.fs;
const process = std.process;

// C imports for Olaf core
const c = @cImport({
    @cInclude("olaf_config.h");
    @cInclude("olaf_reader.h");
    @cInclude("olaf_db.h");
    @cInclude("olaf_deque.h");
});

// ============================================================================
// Unit Tests - Testing C Core Components
// ============================================================================

test "olaf_config: default config creation and destruction" {
    const config = c.olaf_config_default();
    try testing.expect(config != null);
    try testing.expectEqual(@as(c_int, 16000), config.*.audioSampleRate);
    try testing.expectEqual(@as(c_int, 1024), config.*.audioBlockSize);
    c.olaf_config_destroy(config);
}

test "olaf_config: test config creation" {
    const config = c.olaf_config_test();
    try testing.expect(config != null);
    c.olaf_config_destroy(config);
}

test "olaf_config: mem config creation" {
    const config = c.olaf_config_mem();
    try testing.expect(config != null);
    c.olaf_config_destroy(config);
}

test "olaf_config: esp32 config creation" {
    const config = c.olaf_config_esp_32();
    try testing.expect(config != null);
    c.olaf_config_destroy(config);
}

test "olaf_deque: basic operations" {
    const deque = c.olaf_deque_new(100);
    try testing.expect(deque != null);

    c.olaf_deque_push_back(deque, 5);
    c.olaf_deque_push_back(deque, 6);
    c.olaf_deque_push_back(deque, 7);
    c.olaf_deque_push_back(deque, 9);

    try testing.expectEqual(@as(c_uint, 5), c.olaf_deque_front(deque));
    try testing.expectEqual(@as(c_uint, 9), c.olaf_deque_back(deque));

    c.olaf_deque_pop_back(deque);
    try testing.expectEqual(@as(c_uint, 7), c.olaf_deque_back(deque));

    c.olaf_deque_pop_front(deque);
    try testing.expectEqual(@as(c_uint, 6), c.olaf_deque_front(deque));

    try testing.expect(!c.olaf_deque_empty(deque));

    c.olaf_deque_pop_front(deque);
    c.olaf_deque_pop_front(deque);

    try testing.expect(c.olaf_deque_empty(deque));
    c.olaf_deque_destroy(deque);
}

test "olaf_reader: read raw audio file" {
    const audio_file_name = "tests/16k_samples.raw";

    // Check if test file exists
    fs.cwd().access(audio_file_name, .{}) catch |err| {
        std.debug.print("\nSkipping test: {s} not found ({})\n", .{audio_file_name, err});
        return error.SkipZigTest;
    };

    const config = c.olaf_config_test();
    defer c.olaf_config_destroy(config);

    const reader = c.olaf_reader_new(config, audio_file_name);
    try testing.expect(reader != null);
    defer c.olaf_reader_destroy(reader);

    const audio_data = try testing.allocator.alloc(f32, @intCast(config.*.audioBlockSize));
    defer testing.allocator.free(audio_data);

    const samples_expected: usize = @intCast(config.*.audioStepSize);
    var tot_samples_read: usize = 0;

    // Read the first block
    var samples_read = c.olaf_reader_read(reader, audio_data.ptr);
    tot_samples_read += samples_read;

    while (samples_read == samples_expected) {
        samples_read = c.olaf_reader_read(reader, audio_data.ptr);
        tot_samples_read += samples_read;
    }

    try testing.expectEqual(@as(usize, 16000), tot_samples_read);
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
        std.debug.print("Warning: Failed to cleanup test directory {s}: {}\n", .{path, err});
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
