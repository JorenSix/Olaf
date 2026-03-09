const std = @import("std");
const testing = std.testing;
const fs = std.fs;

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
        std.debug.print("\nSkipping test: {s} not found ({})\n", .{ audio_file_name, err });
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
