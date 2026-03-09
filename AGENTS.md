# AGENTS.md

This file provides guidance to AI coding assistants when working with code in this repository.

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
make install            # Install to /usr/local/bin
make mem                # Build memory-only version (for embedded/testing)
make web                # Build WebAssembly version (requires emcc)
make lib                # Build shared library (libolaf.so) for Python wrapper
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
                ↓
              FFT (PFFFT)
                ↓
        Max Filter (Peak Detection)
                ↓
            Event Points
                ↓
           Fingerprints
```

1. **Reader** (`olaf_reader_stream.c`): Streams audio data in blocks (default 1024 samples @ 16kHz)
2. **Stream Processor** (`olaf_stream_processor.c`): Coordinates FFT and processing pipeline
3. **FFT** (`pffft.c`): Fast Fourier Transform to convert to frequency domain
4. **EP Extractor** (`olaf_ep_extractor.c`): Extracts Event Points from spectral peaks using perceptual max filtering (`olaf_max_filter_perceptual_van_herk.c`)
5. **FP Extractor** (`olaf_fp_extractor.c`): Combines 2-3 Event Points into fingerprint hashes with time/frequency deltas
6. **Writers/Matcher**: Store fingerprints or find temporal alignment matches against database

### Database Implementations (Three-Tier Architecture)

Three implementations exist depending on target platform:

- **LMDB** (`olaf_db.c`): B+-tree key-value store for desktop (production)
  - Uses Lightning Memory-Mapped Database for persistent storage
  - Supports multiple concurrent readers, single writer
  - Stores fingerprint hashes as keys with (audio_id, timestamp) as values

- **Memory** (`olaf_db_mem.c`): In-memory array for embedded/testing
  - Fingerprints stored in static arrays or header files
  - No persistent storage, loaded at compile time or initialization
  - Used for ESP32 and similar microcontrollers with limited resources

- **WASM** (`olaf_wasm.c`): Similar to memory version, runs in browsers
  - Compiled with Emscripten (`make web`) or Zig
  - Integrates with Web Audio API for microphone/file input
  - Fingerprints pre-compiled into WASM module

### CLI Interface (Zig)

The CLI is implemented in Zig (`cli/olaf_cli.zig`) and wraps the C core via `olaf_cli_bridge.c`:

- Command structure: Modular commands in `cli/olaf_cli_commands/`
- Each command exports `CommandInfo` struct and `execute` function
- Configuration: JSON-based (`olaf_config.json`), checked in home dir first
- Audio handling: Supports ffmpeg-based decoding in utilities
- Threading: `olaf_cli_threading.zig` provides parallel processing for store/query/cache operations

### Python Wrapper (CFFI)

Located in `python-wrapper/`, provides high-level Python API using CFFI:

**Setup**:
```bash
make lib                                     # Build libolaf.so
pip install -r python-wrapper/requirements.txt
python python-wrapper/setup.py              # Build CFFI wrapper
export LD_LIBRARY_PATH=$(pwd)/bin           # Set library path
```

**Commands**:
- `STORE`: Index audio file or numpy array
- `QUERY`: Find matches, returns dictionary with match details
- `EXTRACT_EVENT_POINTS`: Returns time/frequency pairs (debugging)
- `EXTRACT_FINGERPRINTS`: Returns fingerprint hashes with metadata
- `EXTRACT_MAGNITUDES`: Returns magnitude spectrum (visualization)

Accepts filenames or numpy arrays (mono audio @ 16kHz sample rate).

### Configuration System

**Compile-time config** (`src/olaf_config.c/.h`): Algorithm parameters that affect fingerprint compatibility
- Audio parameters: sample rate (16kHz), block size (1024), step size (128)
- Event point extraction: filter sizes, minimum magnitude thresholds, max EPs per block
- Fingerprint generation: time/frequency distance ranges, number of EPs per FP (2-3)
- Matching parameters: search range, minimum match counts, temporal alignment thresholds
- **Important**: Changes to these make existing databases incompatible with new queries
- Multiple preset configs: `olaf_config_default()`, `olaf_config_esp_32()`, `olaf_config_mem()`, `olaf_config_test()`

**Runtime config** (Zig CLI): Operational settings in `olaf_config.json`
- Database/cache paths (default: `~/.olaf/db/`, `~/.olaf/cache/`)
- Thread counts for parallel processing
- Audio file extensions allowlist
- Query fragmentation settings
- File checked in order: executable dir, `~/.olaf/olaf_config.json`
- Use `olaf config` command to view current configuration

## Testing

### Zig Tests (Recommended - No Ruby Required)
```bash
zig build test              # Run all Zig unit tests
```

The Zig test suite (`tests/olaf_tests.zig`) includes:
- **Unit tests**: Testing C core components (config, deque, reader)
- **Functional tests**: CLI command testing (skeletons provided)
- **Integration tests**: End-to-end pipeline testing (skeletons provided)
- **Benchmark tests**: Performance testing (skeletons provided)

Tests automatically skip when dependencies (ffmpeg, test files) are unavailable.

### C Unit Tests
```bash
make test                   # Build C unit tests
./bin/olaf_tests            # Run C unit tests
```

Legacy C tests in `tests/olaf_tests.c` test deque, max filter, and reader components.

### Ruby Functional Tests (Legacy)
```bash
# Main test suite (requires Ruby, ffmpeg)
ruby eval/olaf_functional_tests.rb

# Test Zig CLI wrapper (requires ffmpeg)
ruby eval/olaf_functional_test_zig_wrapper.rb
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
- Linux: `zig build -Dtarget=x86_64-linux-gnu`
- macOS ARM: `zig build -Dtarget=aarch64-macos.11.0.0-none`
- macOS x86: `zig build -Dtarget=x86_64-macos-gnu`
- WebAssembly: `zig build -Dtarget=wasm32-wasi-musl`

Traditional make + emscripten for web: `make web`

### Docker

Build and run in Docker container (Alpine Linux based):
```bash
docker build -t olaf:1.0 .
docker run -v $HOME/.olaf/docker_dbs:/root/.olaf -v $PWD:/root/audio olaf:1.0 olaf store audio.mp3

# Or with docker compose
docker compose run olaf olaf store dataset/ref/*
docker compose run olaf olaf query dataset/queries/*
```

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

**Core Algorithm**:
- `src/olaf_config.c/h`: Algorithm configuration and presets
- `src/olaf_runner.c/h`: Main execution coordinator
- `src/olaf_stream_processor.c/h`: Audio processing pipeline coordination
- `src/olaf_ep_extractor.c/h`: Event point extraction from spectral peaks
- `src/olaf_fp_extractor.c/h`: Fingerprint generation logic
- `src/olaf_fp_matcher.c/h`: Temporal alignment matching algorithm

**Database Implementations**:
- `src/olaf_db.c/h`: LMDB database for desktop
- `src/olaf_db_mem.c`: Memory database for embedded
- `src/mdb.c`, `src/midl.c`: LMDB implementation (embedded)

**CLI and Wrappers**:
- `cli/olaf_cli.zig`: Main CLI entry point
- `cli/olaf_cli_bridge.c/h`: C bridge for Zig CLI
- `python-wrapper/olaf.py`: Python CFFI wrapper
- `python-wrapper/setup.py`: CFFI build script

**Build System**:
- `build.zig`: Zig build configuration (preferred for new features)
- `Makefile`: Traditional build system

## External Dependencies

- **LMDB**: Embedded in `src/mdb.c`, `src/midl.c` (OpenLDAP Public License)
- **PFFFT**: Fast FFT library in `src/pffft.c` (BSD license)
- **Hash table/queue**: Simon Howard's c-algorithms in `src/hash-table.c`, `src/queue.c` (ISC license)
- **ffmpeg**: External tool for audio decode/resample (not linked, invoked as subprocess)
- **Ruby**: For testing and evaluation scripts (desktop only)
- **Emscripten**: For WebAssembly builds (`make web`)
- **libsamplerate-js**: Audio resampling for browser version (MIT/BSD license)

## Patent Notice

Be aware of patents US7627477 B2 and US6990453 covering acoustic fingerprinting techniques. Olaf's primary purpose is educational and as a learning platform. Consult intellectual property specialists before production use in regions where these patents apply.
