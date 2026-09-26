# Olaf tasks. Run `just` to list them, `just <recipe>` to run one.
# The Makefile and `zig build` remain the build systems; this is a shortcut.

# Port for the browser demos (override: OLAF_PORT=9000 just spectrogram)
port := env_var_or_default("OLAF_PORT", "8000")
opener := if os() == "macos" { "open" } else { "xdg-open" }

# List the recipes
default:
    @just --list --unsorted

# --- Build ---------------------------------------------------------------

# Build the olaf CLI (debug)
build:
    zig build

# Build an optimized olaf CLI
release:
    zig build -Doptimize=ReleaseFast

# Build an optimized CLI and install it to /usr/local/bin
install: release
    make install

# Run the CLI with arguments, e.g. `just run stats`
run *args:
    zig build run -- {{args}}

# Build the browser module into wasm/js/olaf.wasm
web:
    zig build web

# Build the in-memory version bin/olaf_mem (embedded fingerprint headers)
mem:
    make mem

# Build the shared library for the Python wrapper
lib:
    make lib

# Cross-compile an optimized CLI, e.g. `just cross x86_64-windows-gnu`
cross target:
    zig build -Dtarget={{target}} -Doptimize=ReleaseFast

# --- Browser demos (served from the repository root) --------------------

# Simple demo: match microphone input against the compiled-in reference
demo: (_serve "basic.html")

# Detailed demo: spectrogram with event points
spectrogram: (_serve "spectrogram.html")

# Automated browser test with a query from the test dataset
test-page: (_serve "test.html")

# Resampler worklet test
resample: (_serve "resample.html")

# Serve the repository root without opening a page
serve: web
    python3 -m http.server {{port}} --bind 127.0.0.1

# Build the browser module, serve the repository root and open a demo page
_serve page: web
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "{{page}}" = "test.html" ] && [ ! -d dataset/queries ]; then
        echo "The test dataset is missing: run 'just test' first to download it." >&2
    fi
    python3 -m http.server {{port}} --bind 127.0.0.1 &
    server=$!
    trap 'kill $server 2>/dev/null' EXIT INT TERM
    sleep 0.5
    {{opener}} "http://localhost:{{port}}/wasm/{{page}}"
    echo "Serving http://localhost:{{port}}/wasm/{{page}} (Ctrl-C to stop)"
    wait $server

# --- Tests -------------------------------------------------------------

# Run all Zig tests (downloads the test dataset, includes the wasm test)
test:
    zig build test

# Run the browser module test in node (needs ffmpeg and the dataset)
test-wasm: web
    node wasm/olaf_wasm_test.mjs

# Build and run the legacy C unit tests
test-c:
    make test

# Regenerate the output snapshot tests/golden/output_snapshot.txt
golden:
    OLAF_UPDATE_GOLDEN=1 zig build test

# --- Evaluation -------------------------------------------------------

# Recognition benchmark on a folder with music
eval folder:
    python3 eval/olaf_recognition_benchmark.py {{folder}}

# Indexing and query throughput benchmark on a folder with music
benchmark folder:
    python3 eval/olaf_benchmark/olaf_benchmark.py {{folder}}

# --- Other ------------------------------------------------------------

# Generate the doxygen API documentation
docs:
    make docs

# Build the Docker image
docker:
    docker build -t olaf:latest .

# Remove build artifacts
clean:
    make clean
