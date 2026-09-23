# Olaf Tests

## Test files

- `olaf_unit_tests.zig`: unit tests of C core components (config, deque, reader).
- `olaf_functional_tests.zig`: functional tests that run the real `olaf` binary in an isolated HOME, one test per command or behaviour, plus the output snapshot.
- `dataset_download.zig`: downloads (and caches) the test dataset into `dataset/` on first use.
- `golden/output_snapshot.txt`: the exact CLI output locked by the snapshot test.
- `olaf_tests.c`, `16k_samples.raw`: legacy C unit tests (deque, max filter, reader) and their test audio.
- CLI unit tests live next to the code: `cli/olaf_cli_session.zig`, `cli/olaf_cli_threading.zig` and the modules they import (config/schema consistency, store equivalence, output escaping, ...).

## Running tests

```bash
zig build test --summary all        # all Zig tests (builds and installs olaf first)
make test && ./bin/olaf_tests       # legacy C unit tests (make test only builds them)
```

The functional tests need `ffmpeg` and `ffprobe` on the path and skip themselves when they, or the `olaf` binary, are missing. The dataset is downloaded automatically.

## The output snapshot

`functional: output snapshot` stores, queries and prints stats in every output format and compares the result with `golden/output_snapshot.txt`, with machine-dependent values (paths, timings) masked. Fingerprints depend on the audio decoder, so the golden file records the environment it was generated in (arch, OS, ffmpeg version) and the test is skipped elsewhere, e.g. in CI. Regenerate it deliberately, and review the diff, with:

```bash
OLAF_UPDATE_GOLDEN=1 zig build test
```

## Writing functional tests

A `Fixture` sets up an isolated HOME with its own database and cache and runs the CLI in it:

```zig
test "functional: store and query workflow" {
    const allocator = testing.allocator;
    const io = testing.io;
    try dataset.ensureDataset(io, allocator, .ref_only);

    var env = try Fixture.init(allocator, io, "workflow"); // skips without olaf/ffmpeg
    defer env.deinit();

    try env.ok(&.{ "store", env.ref });               // expects exit status 0
    const r = try env.run(&.{ "query", env.ref }, 0); // expected exit status
    defer r.deinit();
    try testing.expect(std.mem.indexOf(u8, r.stdout, "11266") != null);
}
```

Other helpers: `env.expectExit(args, code)`, `env.shell(script, code)`, `env.writeConfig(json)`, `env.songCount()`, `env.storeAllRefs()`, and file helpers such as `touchFile`, `copyFileTo`, `fileExists`. Every run checks its exit status, so a panic always fails the test with the captured output. A new test should fail without the fix it guards.

## Continuous integration

`.github/workflows/make.yml` builds with `make` (default, `mem` and core) and runs `zig build test` on Ubuntu; `.github/workflows/release.yml` cross-compiles the release targets (Linux, macOS, Windows). The legacy C tests are not run in CI.
