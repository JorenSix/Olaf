# Olaf Tests

This directory contains test suites for Olaf in both C and Zig.

## Test Files

- **olaf_tests.c**: Legacy C unit tests (deque, max filter, reader)
- **olaf_tests.zig**: Modern Zig test suite with unit, functional, and integration tests
- **16k_samples.raw**: Test audio data (16kHz, 1 second of audio)
- **olaf_test_db/**: Temporary database for tests

## Running Tests

### Zig Tests (Recommended)

```bash
# Run all Zig tests
zig build test

# Run tests in release mode
zig build test -Doptimize=ReleaseFast
```

### C Unit Tests

```bash
# Build and run C tests
make test
./bin/olaf_tests
```

### Ruby Functional Tests

```bash
# Full functional test suite (requires Ruby, ffmpeg)
ruby eval/olaf_functional_tests.rb
```

## Writing New Tests

### Adding Zig Unit Tests

Add new tests to `olaf_tests.zig`:

```zig
test "my_component: describe what you're testing" {
    // Setup
    const config = c.olaf_config_default();
    defer c.olaf_config_destroy(config);

    // Test
    try testing.expectEqual(@as(c_int, 16000), config.*.audioSampleRate);
}
```

### Adding Functional Tests

Extend the functional test skeletons in `olaf_tests.zig`:

```zig
test "functional: store and query workflow" {
    const allocator = testing.allocator;

    // 1. Create test database
    const test_db = try createTestDbDir(allocator);
    defer cleanupTestDbDir(test_db);

    // 2. Store audio via CLI bridge
    // TODO: Implement using olaf_cli_bridge

    // 3. Query audio
    // TODO: Implement query

    // 4. Verify results
    // TODO: Check matches
}
```

### Test Patterns

**Unit Tests**: Test individual components in isolation
- Config creation/destruction
- Data structure operations (deque, hash table)
- Algorithm components (max filter, FFT)

**Functional Tests**: Test CLI commands end-to-end
- Store → Query workflow
- Delete operations
- Cache operations
- Multi-threaded operations

**Integration Tests**: Test the full pipeline
- Audio → Reader → Stream Processor → EP Extractor → FP Extractor → Matcher
- Database storage and retrieval
- Cross-platform compatibility

**Benchmark Tests**: Performance testing
- Fingerprint extraction speed
- Query response time
- Database scalability

## Test Data

### Creating Test Audio

```bash
# Generate test audio with ffmpeg
ffmpeg -f lavfi -i "sine=frequency=440:duration=1" -ar 16000 -ac 1 -f f32le test.raw
```

### Using Existing Audio

The test suite can use any audio file if ffmpeg is available for decoding.

## Continuous Integration

Tests are automatically run in CI via GitHub Actions:
- `make test` builds and runs C tests
- `zig build test` runs Zig tests
- Ruby functional tests run on push to main

## Test Coverage

To expand test coverage, consider adding tests for:
- [ ] EP extraction with various filter configurations
- [ ] FP matching with different search ranges
- [ ] Database collision handling
- [ ] Multi-threaded store/query operations
- [ ] Error handling and edge cases
- [ ] Memory leak detection (with valgrind)
- [ ] Cross-platform compatibility (Windows, Linux, macOS)

## Troubleshooting

**Test skipped: ffmpeg not available**
- Install ffmpeg: `brew install ffmpeg` (macOS) or `apt-get install ffmpeg` (Linux)

**Test skipped: test file not found**
- Ensure `16k_samples.raw` exists in tests directory
- Regenerate with: `make test`

**C tests fail to link**
- Clean and rebuild: `make clean && make test`
- Ensure all source files are compiled

**Zig tests fail to compile**
- Check Zig version: `zig version` (requires 0.13.0+)
- Update imports in `olaf_tests.zig` if CLI structure changed
