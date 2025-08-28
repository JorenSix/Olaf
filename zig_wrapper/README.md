## Olaf command line interface

This Zig wrapper is the main command line interface for Olaf. 

To Build
````
zig build -Doptimize=ReleaseSmall
zig build run -- config

zig build install-system

````

Cross compilation for Windows

````

zig build  -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSmall
zig build install-system
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