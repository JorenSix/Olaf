# Changelog

All notable changes to Olaf. The release notes on GitHub are taken from the section of the released version.

## [Unreleased]

### Added

- `wasm/spectrogram.html`: a browser demo that draws Olaf's own spectra of the resampled audio (WebGL) with the event points on the block and frequency bin they were found in. It plays the microphone, the test query or a local file. `basic.html` stays the simple demo.
- `node wasm/olaf_wasm_test.mjs` runs the browser module in node: the test query must match, noise must not, and every event point must lie on its spectral peak. `zig build test` runs it (skipped without node, ffmpeg or the dataset).
- An architecture diagram of the Olaf components in the README.

### Changed

- The browser module is built with Zig (`zig build web`, or `make web`) into `wasm/js/olaf.wasm` (about 75KB, checked in). Emscripten is no longer used.
- The worklet is a plain ES module (`wasm/js/olaf_processor.js`) that imports libsamplerate-js 2.1.2 (`libsamplerate.worklet.js`, vendored once instead of three copies) and a shared loader (`olaf_wasm.js`). `wasm/js/olaf.js` creates the worklet node for the demo pages.
- The demos are served from the repository root with `python3 -m http.server`; `wasm/cors_server.py` is removed. The microphone demos switch off echo cancellation, noise suppression and automatic gain control.

### Fixed

- `make web` failed to link with current Emscripten (`--bind`); it now calls `zig build web`.
- `src/olaf_wasm.c` read the configuration before it was initialized on the first call, and passed the matched name as a pointer instead of a string.

## [3.2.0] - 2026-09-26

### Added

- `olaf rest serve`: a REST API over the local database, with `POST /api/store`, `POST /api/query`, `GET /api/stats` and `GET /api/healthz`. Audio is sent as the request body and parameters in the query string.
- `olaf rest serve-lb`: a load balancer with the same API over several `olaf rest serve` instances, for horizontal scaling. It stores on one backend (random, or by identifier hash) and queries all of them.
- Every response lists one result per database plus a combined summary, even when there is only one database.
- `olaf rest store` / `olaf rest query`: store and query through one REST endpoint, with the arguments and output of `olaf store` / `olaf query`. The endpoint is a URL argument or `rest_endpoint`. Through an `olaf rest serve-lb` the output matches that of a single database holding everything, capped at `max_results` matches per query.
- `olaf has` / `olaf rest has`: whether each file is indexed. It runs a fragmented query and reports a match when the best `match_count` reaches `has_min_match_count` or `--threshold`. Output is JSON (with `ffprobe` tags of the matched file, when available) or `--format text`.
- `olaf rest serve` / `serve-lb` own their port: when the port is already in use they stop with an error (exit status 1) instead of sharing it. A stopped server's port can be taken again right away.
- New settings `has_min_match_count`, `rest_endpoint`, `rest_host`, `rest_port`, `rest_max_body_mb`, `rest_workers`, `rest_lb_port`, `rest_lb_backends` and `rest_lb_store_strategy`. `--port` overrides the port.
- The HTTP code lives in `cli/rest/` (Zig module `olaf_rest`, std only) and is linked into the CLI.

## [3.1.1] - 2026-09-24

### Fixed

- Cache and print modes write the final batch of fingerprints at the end of audio. This also fixes missing fingerprints and shortened tail matches when using the cache-backed CLI store path.
- Added dataset regressions checking cache row counts against metadata and comparing tail matches between direct and cache-backed storage.

### Changed

- `olaf stats` prints summary statistics by default. Use `--verbose` or config `"verbose": true` to include the per-file table; neither CLI mode dumps individual fingerprints. The default config remains nonverbose.
- Added `olaf_db_print_stats(db, include_files)` for summary and optional per-file reporting while preserving the legacy `olaf_db_stats()` behavior.

### Validation and compatibility

- Native suite: 77 tests passed, 1 skipped. Clean memory-backend build passed.
- Existing databases remain readable. Regenerate affected caches and re-index affected audio to recover fingerprints omitted by earlier versions; upgrading alone does not restore missing entries.

## [3.1.0] - 2026-09-23

Core safety improvements for native and embedded use. Default fingerprints and existing databases remain compatible; unsafe custom configurations are now rejected.

### Fixed

- Fingerprint database writers flush at buffer capacity, preventing buffer overruns when extraction produces large batches.
- LMDB handles for the same directory share an environment with coordinated writer and snapshot lifetimes, avoiding premature environment closure and races during parallel CLI work.
- Core constructors validate configuration before allocating buffers or opening audio, return NULL with EINVAL for invalid settings, and clean up partial allocations on ENOMEM. Configurations must outlive their objects and structural settings must remain unchanged while in use.
- The CLI validates JSON and programmatic configurations before narrowing C casts, creating storage, decoding audio, or starting workers. The schema documents supported bounds and relationships.
- Event-point extraction uses an owned time-filter scratch buffer; ARM NEON handles short and non-multiple-of-four filters safely.
- Matcher duration conversions use checked double-precision arithmetic, and configuration-sized result buffers are allocated during construction.
- Zig, standalone C, Python, and ESP32 callers handle constructor failures and partial initialization safely.

### Tests

- Added buffer-capacity, LMDB concurrency, configuration-boundary, allocation-failure, C/Zig parity, and Python cleanup regressions.
- Verified native and Linux ASan/UBSan checks, database TSan checks, 32-bit compilation, memory-backend and shared-library builds. ESP32 hardware validation was not run; WASM-specific work is excluded.

## [3.0.0] - 2026-09-23

A robustness release of the Zig command line interface. The C core and its public headers are unchanged, so existing databases stay compatible.

### Breaking changes

- Options and files a command does not use are rejected with exit status 2 instead of silently ignored (e.g. `cache --fragmented`, `store_cached song.mp3`, `query --format human`). A `--with-ids` identifier may not start with `-`.
- Usage errors exit with status 2; processing failures with status 1.
- JSON query output: `fingerprints_matched` is renamed to `query_fingerprints`, which is what it counts.
- `store` numbers stored and skipped files together (`2/5 Skipped ...`); skip records carry an index in every format.
- Release archives ship `olaf_config.example.json` and `olaf_config.schema.json` instead of a live `olaf_config.json`. The previous archives' config next to the binary stored the database in `/tmp` and resampled to 2000 Hz.
- TUI (`olaf` without arguments): `m` matches (queries) the selected file, `q`/`Q` quits.
- `make uninstall` no longer deletes `~/.olaf` (your database).

### Added

- `store` skips already indexed files (`skip_duplicates`); `-f` stores them anyway.
- `-f` for `to_raw`, `to_wav` and `cache` redoes existing outputs; reused outputs are reported.
- Store extraction runs in parallel; only the database write is serialised.
- The config is validated: unknown keys are warned about, wrongly typed values and out-of-range integers are errors. A JSON schema (`cli/olaf_config.schema.json`) matches the code.
- The TUI runs store and query in a background thread, stays responsive, skips already indexed files and writes ffmpeg/core messages to `~/.olaf/olaf_tui.log` (Linux, macOS).

### Fixed

- Crashes and data loss:
  - `delete` of a file that is not indexed no longer kills the run inside the core.
  - The database is checked (writable folder, lock and data files) before workers start, so LMDB errors do not `exit()` halfway through a batch; parallel queries on a new database no longer race.
  - `delete` and queries on a fresh install no longer exit inside the core.
  - An interrupted `cache` no longer blocks a file forever; cache files are written to `.part` files and renamed into place.
  - `store_cached` reports a malformed cache file and continues, with a per-file line and a summary; it stores exactly what `store` stores.
- Output:
  - CSV paths with commas are quoted so strict RFC 4180 readers parse them.
  - JSON is valid for file names that are not UTF-8.
  - Query output is flushed, so live (`microphone`) results are not lost when piped.
  - Long paths and identifiers no longer lose their record.
  - The end-of-query row is kept when only self-matches are found (`dedup`).
  - Output redirected to a file is complete.
  - `delete` and `cache` print one numbered line per file; `dedup --format csv` has a header.
- Paths and platforms:
  - Builds and runs on Windows again; `~` resolves from `USERPROFILE`.
  - Identifiers are derived from the canonical absolute path; symlinked audio files in a folder are stored.
  - Temp raw audio goes to `$TMPDIR` (an empty value is ignored); a missing home directory is an error instead of a literal `./~` folder.
  - `db_folder` without a trailing slash works; directories are processed in sorted order.
- Commands:
  - `--fragmented` honours `fragment_duration_in_seconds` and reports the fragment offset.
  - `microphone` uses per-platform defaults, prints live results, does not leave ffmpeg running on errors and fails clearly on Windows.
  - `clear` deletes only Olaf-owned files, removes temp audio leftovers and accepts `y`/`yes`.
  - `to_raw`/`to_wav` no longer report stale or foreign output as converted.
  - Config files up to 1 MiB are accepted.
- Python wrapper: audio identifiers match the CLI's.
- Make: C builds on Linux (`strdup` declaration), `make test` runs the C tests, `make lib` does not link stale objects.

### Changed

- The C bridge is replaced by a Zig session layer (`cli/olaf_cli_session.zig`, `olaf_cli_core.zig`, `olaf_cli_output.zig`) over the public C API.
- Functional tests use one fixture and an output snapshot (`tests/golden/output_snapshot.txt`).

### Documentation, build and eval

- README, AGENTS.md, test and Windows docs describe the current CLI (TUI, `ffprobe` for `--fragmented`, runtime JSON config, per-platform microphone defaults).
- `eval/olaf_benchmark/olaf_benchmark.py` works again and runs in a sandboxed home; `eval/olaf_memory_use.rb` is repaired; `olaf_result_utils.py merge` takes the fragment length.
- CI runs the C tests and `zig build test`.

### Known limitations

- A read-only `data.mdb` cannot be queried: the bundled LMDB opens a write descriptor for its meta page.
- `store_cached` identifiers longer than 511 bytes are truncated by the core and get a different id than `store` gives them.
- Progress lines go to stdout for some commands and stderr for others.

## [2.0.10] - 2026-06-20

See the [GitHub release](https://github.com/JorenSix/Olaf/releases/tag/v2.0.10).
