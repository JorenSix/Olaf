# Testing Olaf with Zig

This document explains the new Zig-based test system that eliminates the Ruby dependency for unit testing.

## Quick Start

```bash
# Run all Zig tests
zig build test

# Run tests with detailed output
zig build test --summary all

# Run tests in release mode for benchmarks
zig build test -Doptimize=ReleaseFast
```

## Test Suite Overview

The Zig test suite (`tests/olaf_tests.zig`) provides:

### Unit Tests ✅
- **Config tests**: Test all configuration presets (default, test, mem, esp32)
- **Deque tests**: Test push/pop operations, front/back access, empty state
- **Reader tests**: Test reading raw audio files, block processing

### Functional Tests (Skeletons) 🚧
- Store and query workflow
- Config validation
- CLI command integration

### Integration Tests (Skeletons) 🚧
- Full fingerprint extraction pipeline
- End-to-end audio processing

### Benchmark Tests (Skeletons) 🚧
- Fingerprint extraction speed
- Query performance

## Test Results

Current test status:
- ✅ 9 tests passing
- ⏭️ 1 test skipped (requires test audio file or ffmpeg)
- 🚧 Several skeleton tests for future implementation

## Advantages Over Ruby Tests

1. **No Ruby dependency**: Only requires Zig compiler
2. **Type safety**: Zig's type system catches errors at compile time
3. **Cross-platform**: Works on Windows, macOS, Linux without modification
4. **Fast compilation**: Zig compiles tests quickly
5. **Integrated**: Tests run as part of `zig build` workflow
6. **C interop**: Direct testing of C functions via `@cImport`

## Test Structure

```zig
test "component: what we're testing" {
    // 1. Setup
    const config = c.olaf_config_default();
    defer c.olaf_config_destroy(config);  // Cleanup automatically

    // 2. Execute
    const result = someOperation(config);

    // 3. Assert
    try testing.expectEqual(expected, result);
}
```

## Extending Tests

### Adding a New Unit Test

Edit `tests/olaf_tests.zig`:

```zig
test "my_component: describe the test" {
    // Your test code here
    try testing.expect(true);
}
```

### Testing C Functions

Use `@cImport` to access C functions:

```zig
const c = @cImport({
    @cInclude("your_header.h");
});

test "c_function: test description" {
    const result = c.your_c_function();
    try testing.expectEqual(@as(c_int, 42), result);
}
```

### Skipping Tests Conditionally

```zig
test "requires_ffmpeg: test description" {
    // Check if ffmpeg exists
    std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &[_][]const u8{ "ffmpeg", "-version" },
    }) catch {
        // Skip test if ffmpeg not available
        return error.SkipZigTest;
    };

    // Test code here...
}
```

## Test Patterns

### Memory Management

Always use `defer` for cleanup:

```zig
const config = c.olaf_config_default();
defer c.olaf_config_destroy(config);  // Runs at end of scope
```

### Error Handling

Use `try` for functions that can fail:

```zig
const file = try std.fs.cwd().openFile("test.raw", .{});
defer file.close();
```

### Assertions

Common assertion patterns:

```zig
try testing.expect(condition);              // Assert true
try testing.expectEqual(expected, actual);  // Assert equality
try testing.expectError(error.Foo, func()); // Assert error
```

## CI Integration

Tests run automatically in GitHub Actions:

```yaml
- name: Run Zig tests
  run: zig build test
```

## Future Work

Skeleton tests marked with 🚧 need implementation:

1. **Functional tests**: Implement store/query workflows
2. **Integration tests**: Test full audio processing pipeline
3. **Benchmark tests**: Add timing and performance measurements
4. **Audio generation**: Create test audio files programmatically
5. **Database tests**: Test LMDB operations
6. **Multi-threading tests**: Test parallel store/query operations

## Troubleshooting

**Test compilation fails**:
```bash
zig build test --verbose  # See detailed compilation errors
```

**Test skipped unexpectedly**:
- Check if required files exist (16k_samples.raw)
- Check if ffmpeg is installed: `ffmpeg -version`

**Memory leaks**:
```bash
# Run with valgrind (Linux/macOS)
zig build test -Doptimize=Debug
valgrind --leak-check=full zig-out/bin/olaf-tests
```

## Comparison with Other Test Systems

| Feature | Zig Tests | C Tests (make test) | Ruby Tests |
|---------|-----------|---------------------|------------|
| Dependency | Zig only | gcc, make | Ruby, ffmpeg |
| Speed | Fast | Fast | Slower |
| Cross-platform | ✅ | ⚠️ Requires make | ⚠️ Requires Ruby |
| Type safety | ✅ | ❌ | ❌ |
| Integration | `zig build test` | `make test` | Custom script |
| C interop | Direct | Native | FFI |

## Resources

- [Zig Testing Documentation](https://ziglang.org/documentation/master/#Testing)
- [Olaf Test Suite](../tests/olaf_tests.zig)
- [Test README](../tests/README.md)
