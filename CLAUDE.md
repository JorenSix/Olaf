# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Olaf (Overly Lightweight Acoustic Fingerprinting) is an acoustic fingerprinting system designed to run efficiently on embedded platforms, traditional computers, and in web browsers via WebAssembly. The project extracts audio fingerprints and stores/matches them against a database for content-based audio search.

### Key Design Constraints
- **Portable C11**: Core implementation in C11 for embedded compatibility
- **Memory efficiency**: Designed for 32-bit ARM platforms (ESP32, Teensy, Arduino)
- **Multi-target**: Supports embedded (memory DB), desktop (LMDB), and web (WASM)
- **Patent awareness**: Implementation is primarily for learning; be aware of US7627477 B2 and US6990453

## Build System

The project uses **two build systems**:

### 1. Makefile (Traditional)
```bash
make                    # Build default version with LMDB
make install            # Install to /usr/local/bin (requires Ruby wrapper)
make mem                # Build memory-only version (for embedded/testing)
make web                # Build WebAssembly version (requires emcc)
make test               # Build and run unit tests
make clean              # Clean build artifacts
```

### 2. Zig Build (Modern, Cross-Platform)
```bash
zig build                            # Build CLI version with LMDB
zig build -Dcore=true                # Build core C library only
zig build -Doptimize=ReleaseSmall   # Optimized build
zig build run -- [args]              # Build and run with arguments
zig build install-system             # Install to system location
zig build -Dtarget=x86_64-windows-gnu  # Cross-compile for Windows
zig build -Dtarget=wasm32-wasi-musl    # Build for WebAssembly
```

**When modifying build logic**: The Zig build is the modern approach and should be preferred for new features.

## Code Architecture

### Core Processing Pipeline

```
Audio Input → Reader → Stream Processor → EP Extractor → FP Extractor → DB Writer/Matcher
```

1. **Reader** (`olaf_reader_stream.c`): Streams audio data in blocks
2. **Stream Processor** (`olaf_stream_processor.c`): Coordinates FFT and processing
3. **EP Extractor** (`olaf_ep_extractor.c`): Extracts Event Points from spectral peaks using max filtering
4. **FP Extractor** (`olaf_fp_extractor.c`): Combines Event Points into fingerprints
5. **Writers/Matcher**: Store fingerprints or match against database

### Database Implementations

Three implementations exist depending on target:

- **LMDB** (`olaf_db.c`): B+-tree key-value store for desktop (production)
- **Memory** (`olaf_db_mem.c`): In-memory array for embedded/testing
- **WASM**: Similar to memory version, uses header files

### CLI Interface (Zig)

The CLI is implemented in Zig (`cli/olaf_cli.zig`) and wraps the C core via `olaf_cli_bridge.c`:

- Command structure: Modular commands in `cli/olaf_cli_commands/`
- Each command exports `CommandInfo` struct and `execute` function
- Configuration: JSON-based (`olaf_config.json`), checked in home dir first
- Audio handling: Supports ffmpeg-based decoding in utilities

### Configuration System

**Compile-time config** (`src/olaf_config.c`): Algorithm parameters (FFT size, event point thresholds, etc.)
- Changes to these parameters make databases incompatible with queries
- Multiple preset configs: `olaf_config_default()`, `olaf_config_esp_32()`, `olaf_config_mem()`

**Runtime config** (Zig CLI): Paths, thread counts, file extensions
- `olaf_config.json` in executable dir or `~/.olaf/olaf_config.json`
- Use `olaf config` to view current configuration

## Testing

### Functional Tests
```bash
# Main test suite (requires Ruby, ffmpeg)
ruby eval/olaf_functional_tests.rb

# Test Zig CLI wrapper
ruby eval/olaf_functional_test_zig_wrapper.rb
```

### Unit Tests
```bash
make test
./bin/olaf_tests
```

### Evaluation & Benchmarking
```bash
# Download test dataset
ruby eval/olaf_download_dataset.rb

# Run evaluation with modifications (requires SoX)
ruby eval/olaf_evaluation.rb /folder/with/music

# Benchmark indexing and query performance
ruby eval/olaf_benchmark/olaf_benchmark.rb /folder/with/music
```

## Development Notes

### When Adding New Commands

1. Create new file in `cli/olaf_cli_commands/olaf_cli_cmd_[name].zig`
2. Export `CommandInfo` struct with name, description, help, and needs_audio_files
3. Implement `execute(allocator: std.mem.Allocator, args: *types.Args) !void`
4. Register in `cli/olaf_cli.zig` commands array

### When Modifying Core Algorithm

- **Always rebuild completely**: `make clean && make` or `zig build`
- Algorithm changes in `src/` may require database re-indexing
- Test both desktop (LMDB) and memory versions if changing core processing
- Update configuration in `olaf_config.c` if adding new parameters

### Embedded Development

For ESP32/embedded targets:
1. Build memory version: `make mem`
2. Generate header file index:
   ```bash
   olaf to_raw audio.mp3
   bin/olaf_mem store olaf_audio_audio.raw "identifier" > fingerprints.h
   ```
3. Include header in ESP32 project

### Cross-Compilation

Zig makes cross-compilation trivial:
- Windows: `zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSmall`
- WebAssembly: `zig build -Dtarget=wasm32-wasi-musl`

Traditional make + emscripten for web: `make web`

## Common Patterns

### OOP-Style C
The C code uses OOP-inspired patterns:
- Structs with constructor/destructor: `olaf_*_new()` / `olaf_*_destroy()`
- Function pointers for polymorphism (see database interface)
- Opaque pointers in headers, implementation in .c files

### Memory Management
- C core: Manual malloc/free, caller responsible for cleanup
- Zig CLI: Arena allocators, GPA with defer statements
- Always pair `_new()` with `_destroy()` calls

### Threading
- Core C library is single-threaded (embedded compatibility)
- Zig CLI implements multi-threading for query/store commands
- Use `--threads n` flag for parallel processing on desktop

## Important Files

- `src/olaf_config.c/h`: Algorithm configuration
- `src/olaf_runner.c/h`: Main execution coordinator
- `src/olaf_fp_extractor.c`: Fingerprint generation logic
- `src/olaf_fp_matcher.c`: Matching algorithm
- `cli/olaf_cli.zig`: Main CLI entry point
- `build.zig`: Zig build configuration
- `Makefile`: Traditional build system

## External Dependencies

- **LMDB**: Embedded in `src/mdb.c`, `src/midl.c` (OpenLDAP Public License)
- **PFFFT**: FFT library in `src/pffft.c` (BSD license)
- **ffmpeg**: External dependency for audio decode/resample (not bundled)
- **Ruby**: For wrapper scripts and testing (desktop only)
