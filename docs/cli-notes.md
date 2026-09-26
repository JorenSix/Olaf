## Olaf command line interface

This Zig wrapper is the main command line interface for Olaf. 

To Build
````
# for the olaf_core C executable
zig build -Dcore=true

#for olaf cli, default
zig build -Dcore=false
#or simply
zig build

# for an optimized version
zig build -Doptimize=ReleaseSmall
zig build run -- config

#to install the cli (Makefile)
make install

````

Cross compilation for Windows, CLI

````
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSmall
file zig-out/bin/olaf.exe # PE32+ executable (console) x86-64, for MS Windows
````

### Configuring of Olaf

Olaf looks for a configuration file named `olaf_config.json` in the same directory as the executable and in the users home directory `~/.olaf/olaf_config.json`. If a configuration file is found in the home directory it takes precedence over the config file in the executable directory. If no config files is found, defaults are used. 
To check the configuration in use print `olaf config`/


## Store 


This command needs audio files, none are found.
olaf store [audio_file...] | --with-ids [audio_file audio_identifier]

## Olaf Command Line Tool Documentation

### Commands

#### `to_wav`
Converts audio files to single channel WAV format.
- **Usage:** `olaf to_wav [--threads n] audio_files...`
- **Options:**
    - `--threads n`: Specifies the number of threads to use for conversion.

#### `stats`

Prints statistics about the audio files stored in the database.
- **Usage:** `olaf stats`

#### `store`

Extracts and stores audio fingerprints into an index.
- **Usage:** 
    - `olaf store [audio_file...]`
    - `olaf store --with-ids [audio_file audio_identifier]`
- **Options:**
    - `--with-ids`: Stores audio files with user-provided identifiers.

#### `rest serve`
Serves the REST API for the local database on `rest_host:rest_port` (default `127.0.0.1:8920`).
- **Usage:** `olaf rest serve [--port n]`
- **Endpoints:** `POST /api/store?identifier=id[&force]`, `POST /api/query[?identifier=label&no_identity_match&fragmented]` (audio as the request body), `GET /api/stats`, `GET /api/healthz`.
- **Options:**
    - `--port n`: Listens on port `n` instead of `rest_port`.

#### `has`
Checks whether audio is in the database: a fragmented query per file. It is a match when the best `match_count` reaches `has_min_match_count` (default 20). Output is one JSON line per file, with the `ffprobe` tags of the matched file when its identifier is an existing absolute path, or one text line with `--format text`.
- **Usage:** `olaf has [--threshold n] [--threads n] [--format <json|text>] [audio_file...] | --with-ids [audio_file audio_identifier]...`

#### `rest has`
`olaf has` through one REST endpoint, with the same output. Tags are read on the client.
- **Usage:** `olaf rest has [url] [--threshold n] [--threads n] [--format <json|text>] [audio_file...]`

#### `rest store` / `rest query`
Store or query through one REST endpoint (`olaf rest serve` or `olaf rest serve-lb`) instead of the local database. Output is the same as `olaf store` / `olaf query`.
- **Usage:**
    - `olaf rest store [url] [--threads n] [-f] [--format <human|csv|json>] [audio_file...] | --with-ids [audio_file audio_identifier]...`
    - `olaf rest query [url] [--threads n] [--fragmented] [--no-identity-match] [--format <csv|json>] [audio_file...] | --with-ids ...`
- **Endpoint:** `url` (`http://` or `https://`), or config `rest_endpoint`. Only one endpoint: to combine databases, use an `olaf rest serve-lb` URL.

#### `rest serve-lb`
Serves the same API on `rest_host:rest_lb_port` (default `127.0.0.1:8921`), answered by the `olaf rest serve` instances in `rest_lb_backends`. A store goes to one backend (`rest_lb_store_strategy`: `random` or `hash`). Query, stats and health go to all backends, and their results are combined in one response.
- **Usage:** `olaf rest serve-lb [--port n]`
- **Options:**
    - `--port n`: Listens on port `n` instead of `rest_lb_port`.

#### `config`
Displays the current configuration in use.
- **Usage:** 
    - `olaf config`

#### `query`
Queries the database for fingerprint matches.
- **Usage:** 
    - `olaf query [--threads n] [audio_file...]`
    - `olaf query --with-ids [audio_file audio_identifier]`
- **Options:**
    - `--threads n`: Specifies the number of threads to use for querying.
    - `--with-ids`: Queries using user-provided identifiers.