# Changelog

All notable changes to Olaf. The release notes on GitHub are taken from the section of the released version.

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
