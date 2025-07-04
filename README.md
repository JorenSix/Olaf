# OLAF - Overly Lightweight Acoustic Fingerprinting

![Olaf build and test status](https://github.com/JorenSix/Olaf/actions/workflows/make.yml/badge.svg)![Olaf Zig build](https://github.com/JorenSix/Olaf/actions/workflows/zigbuild.yml/badge.svg) [![JOSS Paper](https://joss.theoj.org/papers/f5b4572fd51939c2ab8363e561bdb2b7/status.svg)](https://joss.theoj.org/papers/f5b4572fd51939c2ab8363e561bdb2b7)

Olaf is a C application or library for content-based audio search. Olaf is able to extract fingerprints from an audio stream, and either store those fingerprints in a database, or find a match between extracted fingerprints and stored fingerprints. Olaf does this efficiently in order to be used on **embedded platforms**, traditional computers or in web browsers via WASM.

Please be aware of the patents US7627477 B2 and US6990453 and perhaps others. They describe techniques used in algorithms implemented within Olaf. These patents limit the use of Olaf under various conditions and for several regions. Please make sure to consult your intellectual property rights specialist if you are in doubt about these restrictions. If these restrictions apply, please **respect the patent holders rights**. The main aim of Olaf is to serve as a learning platform on efficient (embedded) acoustic fingerprinting algorithms.

## Overview

1. [Why Olaf?](#why-olaf)
2. [Olaf on traditional computers](#olaf-on-traditional-computers)
   - [Compilation and installation](#compilation-and-installation)
   - [Compilation with Zig](#compilation-with-zig)
   - [Olaf on Windows](#olaf-on-windows)
   - [Olaf on Docker](#olaf-on-docker)
3. [Olaf in the browser](#olaf-in-the-browser)
4. [Embedded Olaf](#embedded-olaf)
5. [Olaf Usage](#olaf-usage)
   - [Store fingerprints](#store-fingerprints)
   - [Query fingerprints](#query-fingerprints)
   - [Delete fingerprints](#delete-fingerprints)
   - [Deduplicate a collection](#deduplicate-a-collection)
   - [Database stats](#database-stats)
   - [Cache fingerprints and store cached fingerprints](#cache-fingerprints-and-store-cached-fingerprints)
6. [Configuring Olaf](#configuring-olaf)
7. [Testing, evaluating and benchmarking Olaf](#testing-evaluating-and-benchmarking-olaf)
   - [Testing Olaf](#testing-olaf)
   - [Evaluating Olaf](#evaluating-olaf)
   - [Benchmarking Olaf](#benchmarking-olaf)
8. [Contribute to Olaf](#contribute-to-olaf)
9. [Olaf documentation](#olaf-documentation)
10. [Limitations of Olaf](#limitations-of-olaf)
11. [Further Reading](#further-reading)
12. [Credits](#credits)

## Why Olaf?

With respect to other audio search systems, Olaf stands out for three reasons:

* Olaf runs on embedded devices.
* Olaf is fast on traditional computers.
* Olaf runs in the browsers.

There seem to be no lightweight acoustic fingerprinting libraries that are straightforward to run on embedded platforms. On embedded platforms memory and computational resources are severely limited. Olaf is written in portable C with these restrictions in mind. Olaf mainly targets 32-bit ARM devices such as some Teensy's, some Arduino's and the ESP32. Other modern **embedded platforms** with similar specifications and should work as well.

Olaf, being written in portable C, also targets **traditional computers**. There, the efficiency of Olaf makes it run fast. On embedded devices reference fingerprints are stored in memory. On traditional computers fingerprints are stored in a high-performance key-value-store: LMDB. LMDB offers a B+-tree based persistent storage ideal for small keys and values with low storage overhead.

Olaf works in **the browser**. Via Emscripten Olaf can be compiled to [WASM](https://en.wikipedia.org/wiki/WebAssembly). This makes it relatively straightforward to combine the capabilities of the [Web Audio API](https://developer.mozilla.org/en-US/docs/Web/API/Web_Audio_API) and Olaf to create browser based audio fingerprinting applications.

![Olaf in the browser](./docs/olaf_in_browser.png)
*Olaf running in a browser*

Olaf was featured on [hackaday](https://hackaday.com/2020/08/30/olaf-lets-an-esp32-listen-to-the-music/). There is also a small discussion about Olaf on [Hacker News](https://news.ycombinator.com/item?id=24292817).

## Olaf on traditional computers

To use Olaf `ffmpeg` and `ruby` need to be installed on your system. While the core of Olaf is in pure c, a Ruby script provides an easy to use interface to its capabilities. The Ruby script converts audio (with `ffmpeg`), parses command line arguments and reports results in a readable format.

To install ffmpeg and ruby on a Debian like system: `apt-get install ffmpeg ruby`. On macOS ruby is available by default and `ffmpeg` can be installed with [homebrew](https://brew.sh/) by calling `brew install ffmpeg`.

### Compilation and installation

To compile the version with a key value store for traditional computers use the following. By default the makefile uses `gcc` set to the C11 standard. Other compilers compliant with the C11 standard work equally well. Make sure `gcc` is installed correctly or modify the Makefile for your compiler of choice. Compilation and installation:

```bash
#sudo apt-get install ffmpeg ruby
git clone https://github.com/JorenSix/Olaf
cd Olaf
make
sudo make install
```

By default, a directory named `.olaf` is created in the current user home directory. The command line script is installed to `/usr/local/olaf`, which is assumed to be on the user's path.

### Compilation with Zig

Alternatively you can build Olaf with [zig](https://ziglang.org/). Zig is a programming language which also ships with a c compiler. In this project Zig is employed as an easy to use cross-compiler.

A `build.zig` file is provided. Just call "zig build" to compile for your platform. On an M1 mac it gives the following:

```bash
zig build
file zig-out/bin/olaf_c # Mach-O 64-bit executable arm64
```

The power of Zig is, however, more obvious when an other target is provided. For a list of platforms, please consult the output of `zig targets`. To build a windows executable run the following commands.

```bash
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSmall
file zig-out/bin/olaf_c.exe # PE32+ executable (console) x86-64, for MS Windows
```

Zig also supports WebAssembly as a target platform as an alternative to Emscripten. The `build.zig` file includes a conditional to build the memory db for WASM. To get a WASM binary call the following:

```bash
zig build -Dtarget=wasm32-wasi-musl -Doptimize=ReleaseSmall
file zig-out/bin/olaf_c.wasm #WebAssembly (wasm) binary module version 0x1 (MVP)
```

### Olaf on Windows

Olaf has been designed with a UNIX like environment in mind but also works on Windows. A pre-built windows executable can be found in the `pre-built` folder. There is additional [documentation for running Olaf on Windows](pre-built/README.textile).

### Olaf on Docker

Olaf can be containerized with [Docker](https://www.docker.com/). The provided Dockerfile is based on [Alpine linux](https://www.alpinelinux.org/) and installs only the needed requirements. A way to build the container and run Olaf:

```bash
docker build -t olaf:1.0 .
wget "https://filesamples.com/samples/audio/mp3/sample3.mp3"
docker run -v $HOME/.olaf/docker_dbs:/root/.olaf -v $PWD:/root/audio olaf:1.0 olaf store sample3.mp3
docker run -v $HOME/.olaf/docker_dbs:/root/.olaf -v $PWD:/root/audio olaf:1.0 olaf stats
```

In this case the `$HOME/.olaf/docker_dbs` is mapped to `/root/.olaf` in the container to store the database. The audio enters the system via a mapping of `$PWD` to `/root/audio` in the container, which is also the work directory in the container. So relative paths with respect to `$PWD` of the host can be resolved in the container, absolute paths can not.

If you prefer docker compose the following should get you started:

```bash
ruby eval/olaf_download_dataset.rb 
docker compose run olaf olaf store dataset/ref/*
docker compose run olaf olaf query dataset/queries/*
docker compose   run --remove-orphans olaf olaf stats 
```

## Olaf in the browser

To compile Olaf to WASM the `emcc` compiler from Emcripten is used. Make sure [Emscripten is correctly installed](https://emscripten.org/docs/getting_started/downloads.html) and run the following:

```bash
make web

python3 -m http.server --directory wasm #start a web browser
open "http://localhost:8000/spectrogram.html" #open the url in standard browser
```

Note that the web version does not use a key value store but a list of hashes stored in a header-file. See below for more info.

## Embedded Olaf

Olaf has been tested on the ESP32 microcontroller. Other, similar microcontrollers might work as well. The embedded version does not use a key value store but a list of hashes stored in a `.h` header file. This header file is the fingerprint index.

The 'index' or header file can be created on a computer to contain fingerprints extracted from audio. To create this header file do the following:

```bash
make mem
olaf to_raw your_audio_file.mp3
bin/olaf_mem store olaf_audio_your_audio_file.raw "arandomidentifier" > your_header_file.h
```

To test and debug this header file, use the `mem` version of Olaf on your computer. The ESP32 version is basically the same as the `mem` version, only the audio comes from microphone input and not from a file.

## Olaf Usage

On traditional computers, Olaf provides a *command line interface* it can be called using `olaf sub-application [argument...]`. For each task Olaf has to perform, there is a sub-application. There are sub-applications to store fingerprints, to query audio fragments,... . A typical interaction with Olaf could look like this:

![Olaf interaction](./docs/olaf_interaction.svg)

In a more copy-paste friendly way the following demonstrates example use of Olaf. In the example, first a dataset is downloaded then all audio files in a folder are indexed. Then statistics about the index are printed. Finally a folder is deduplicated: the duplicates material in a folder are identified and the duplicate is removed.

```bash
git clone https://github.com/JorenSix/Olaf
cd Olaf
make && make install
ruby eval/download_dataset.rb

#store all audio in a folder and execute a query
olaf store dataset/ref
olaf query dataset/queries/1051039_34s-54s.mp3

#print statistics of the index:
olaf stats

#Deduplication of a folder with duplicate material
ffmpeg -i dataset/ref/173050.mp3 dataset/ref/173050_dup.ogg
olaf dedup dataset/ref

#delete the duplicate from the index:
olaf delete dataset/ref/173050_dup.ogg
rm  dataset/ref/173050_dup.ogg
```

### Store fingerprints

The store command extracts fingerprints from an audio file and stores them in a reference database. The incoming audio is decoded and resampled using `ffmpeg`. `ffmpeg` needs to be installed on your system and available on the path.

```bash
olaf store audio_item...
```

The `audio_item` can be:

1. An audio file: `olaf store audio.mp3`, if the audio file contains multiple channels they are mixed to a mono.
2. A video file. The **first audio stream** is extracted from the video container and used as input: `olaf store video.mkv`
3. A folder name: Olaf attempts to **recursively** find all audio files within the folder. It does this with a limited allowlist of known audio file name extensions. `olaf store /home/user/Music`
4. A text file: The text file should contain a list of file names. The following commands recursively finds all mp3 within the current directory and subsequently stores them in the reference database.

```bash
find . -name "*.mp3" > list.txt
olaf store list.txt
```

Internally each audio stream is given an identifier using a one time [Jenkins Hash](https://en.wikipedia.org/wiki/Jenkins_hash_function) function. This identifier is returned when a match is found. A list connecting these identifiers to file names is also stored automatically.

### Query fingerprints

The query command extracts fingerprints and matches them with the database:

```bash
olaf query [--threads n] [--fragmented] [--no-identity-match] query.opus
```

The query command has several options.

**--threads n** tells Olaf to use multiple threads to query the index. This can significantly speed up matching if multiple cores are available on your system.

**--fragmented** this splits query file into steps of x seconds. When working in steps of 5 seconds, then the first five seconds are matched with the reference database and matches are reported. Subsequently it goes on with the next 5 seconds and so forth. This is practical if an unsegmented audio file needs to be matched with the reference database.

**--no-identity-match** If the query is present in the index it obviously matches itself. This option prevents identity matches to be reported. This is useful for deduplication.

To query audio coming from the microphone there is the `olaf microphone` command. It uses ffmpeg to access the default microphone. See [the `ffmpeg` input devices docs for your platform](http://www.ffmpeg.org/ffmpeg-devices.html#Input-Devices)

```bash
ffmpeg -f avfoundation -list_devices true -i ""
```

```bash
ffmpeg -f avfoundation -i "none:default" -ac 1 -ar 16000 -f f32le -acodec pcm_f32le pipe:1 | olaf query
```

### Delete fingerprints

Deletion of fingerprints is similar to adding prints:

```bash
olaf delete item.mp3
```

Note that it is currently unclear what the performance implications are when adding and removing many items to the db. In other words: how balanced the B+ tree remains with many leaves removed. To make sure the tree remains balanced it is always an option to clear the database and re-index the audio:

```bash
olaf clear
```

The clear command deletes the database and optionally clears the folder with cached fingerprints. It requests permission before deleting. To force deletion the `-f` flag can be used: `olaf clear -f`.

### Deduplicate a collection

This command finds duplicate audio content in a folder. First each audio file is stored in the reference database. Next each file is used as a query and matched with the reference database. The file should, evidently, match itself but self-matches are ignored, leaving only duplicates.

A duplicate means that audio from the original is found in another file. The start and stop times of the found fragment are reported. If the match reports a start of nearly zero and a duration similar to the duration of the original audio file then a 'full duplicate' is found: it is almost certainly the same exact track. If only a couple of seconds are reported it means that only a couple of seconds of the original audio are found in the duplicate.

```bash
olaf dedup [--threads n] [--fragmented] field_recordings/archive
```

**--threads n** tells Olaf to use multiple threads to query the index. This can significantly speed up matching if multiple cores are available on your system.

**--fragmented** this tells Olaf to split the query file into steps of x seconds during matching. When working in steps of 5 seconds, then the first five seconds are matched with the reference database and matches are reported. Subsequently it goes on with the next 5 seconds and so forth. This is practical for partial matches with the reference database.

### Database stats

To get statistics on the database use `stats`. It prints information on the b-tree structure backing the storage.

```bash
olaf stats
```

### Cache fingerprints and store cached fingerprints

Caching prints can be practical to speed up indexing. Olaf is single threaded mainly for use on embedded platforms. Additionally, the data storage of Olaf only allows one write thread (multiple readers are allowed). However, on more powerful computing machinery it might be of interest to use multiple cores to extract fingerprints. This can speed up indexing significantly.

The way around this is to cache fingerprints to a file with all available cores - or multiple machines - and later store all prints in the index.

```bash
olaf cache [--threads n] *.mp3
olaf store_cached
```

Note that for multi-threading to work, the `threach` ruby gem is required. Install this with `gem install threach`. Also a default is the storage place for cached items: `~/.olaf/cache`. These default can be changed in the `/usr/local/bin/olaf` ruby file. The configuration can be found at the top.

## Configuring Olaf

Olaf has a number of configuration parameters. Currently these are done during compile time in the `olaf_config.c` file. This is to avoid changing configuration at runtime which could result in an index being not compatible with fingerprints extracted from a query (with different configuration parameters).

The configuration includes the amount of fingerprints extracted, the location of the data directory, configuration related to matching, ... Each configuration setting has a small description. There is a default configuration for `mem`, `web` and `default` cases which slightly differ.

The olaf.rb Ruby script also contains a few settings related to how audio is decoded, where data is expected, the number of threads which can be used,... To change these settings, edit the script itself (typically located at `/usr/local/bin/olaf`. Changes to configuration there are immediately applied.

## Testing, Evaluating and Benchmarking Olaf

The tests check **whether Olaf works**. The evaluation verifies **how well** Olaf works. The benchmark checks **how fast** Olaf works and how it deals with scalability.

[More details on testing, evaluating and benchmarking Olaf](./eval) can be found in the separate page. There information on memory use can be found together with a comparison against Panako.

### Testing Olaf

The first thing this checks is whether Olaf compiles correctly. Afterwards, a small dataset is indexed and some queries are fired. The result of the queries is evaluated for correctness. Also the memory version of Olaf is checked. To run this yourself, with Ruby, `ffmpeg` and `ffprobe` installed:

```bash
git clone https://github.com/JorenSix/Olaf
cd Olaf
make && make install
ruby eval/olaf_functional_tests.rb
```

Less interesting are the unit tests, these are mainly of interest for developing Olaf. The unit test can be compiled with `make test` and ran with `./bin/olaf_tests`.

### Evaluating Olaf

In the `eval` folder there is an evaluation script which takes a folder as input and stores and evaluates queries with several modifications. [SoX](https://sox.sourceforge.net/) needs to be available on the system for this to work.

```bash
ruby eval/olaf_evaluation.rb /folder/with/music
```

### Benchmarking Olaf

With the script a folder of audio files is stored and it is registered how long it takes to store 64, 128, 256, 512,... files. If run with the [FMA full](https://github.com/mdeff/fma) dataset a total of more than 200 days of audio are stored at a rate of just under 2000 times real-time with a 96 CPU-core system. An interpretation of the graph is that indexing remains linear on larger datasets. At every doubling of the database the [query performance](./eval/olaf_benchmark/olaf_benchmark_query.svg) is also checked. Run the benchmark yourself:

```bash
ruby eval/olaf_benchmark/olaf_benchmark.rb /folder/with/music
```

![Olaf indexing](./eval/olaf_benchmark/olaf_benchmark.svg)

## Contribute to Olaf

There are several ways to contribute to Olaf. The first is to use Olaf and report issues or feature requests using the Github Issue tracker. Bug reports are greatly appreciated, but keep in mind the note below on responsiveness.

Another way to contribute is to dive into the code, fork and improve Olaf yourself. Merge requests with additional documentation, bug fixes or new features will be handled and end up in the main branch if correctness, maintainability and simplicity are kept in check. However, keep in mind the note below:

My time to spend on Olaf is limited and goes in activity bursts. If an issue is raised it might take a couple of months before I am able to spend time on it during the next burst of activity. A period of relative silence does not mean your feedback / pull request is not greatly valued!

## Olaf documentation

The [documentation of Olaf](https://jorensix.github.io/Olaf) is generated with [doxygen](http://doxygen.nl) and can be consulted on github via the gh-pages branch.

## Limitations of Olaf

* ~~Currently a complete audio file is read in memory in order to process it. While the algorithm allows streaming, the current implementation does not allow to store incoming streams.~~ Now you can choose whether to compile in the single or stream reader: choose either `olaf_reader_single.c` or `olaf_reader_stream.c`, which is a bit slower.
* Only one write process: LMDB limits the number of processes that can write to the key-value store to a single process. Attempting to write to the key-value store while an other write-process is busy should put the process automatically in a wait state untile the write lock is released (by the other process). Reading can be done frome multiple processes at the same time.
* Audio decoding is done externally. The core of Olaf does fingerprinting. ffmpeg or similar audio decoding software is required to decode and resample various audio formats.
* ~~Removing items from the reference database is currently not supported. The underlying database does support deletion of items so it should be relatively easy to add this functionality.~~
* Performance implications when removing many items from the database are currently unclear. In other words: how balanced does the B+tree remain when removing many leaves.
* Olaf is single threaded. The main reasons are simplicity and limitations of embedded platforms. The single threaded design keeps the code simple. On embedded platforms with single core CPU's multithreading makes no sense. On traditional computers there might be a performance gain by implementing multi-threading. However, the time spent on decoding audio and storing fingerprints is much larger than analysis/extraction so the gain might be limited. As an work-around multiple processes can be used simultaniously to query the database.
* The limitation of the number of tracks that can be indexed and queried on a single computer is not known. Olaf has been used to index and query the [fma_full dataset](https://github.com/mdeff/fma). This dataset contains 100 000 tracks totaling more than 340 days of audio. The dataset, around 800GB of mp3s, were indexed in a 15GB database and query speed remained at a respectable 80 times realtime: it only takes a single second to query 80 seconds of audio. With the datastructure having logaritmic complexity the limit of the number of songs per pc might be a couple of times higher.

## Further Reading

Some relevant reading material about (landmark based) acoustic fingerprinting. The order gives an idea of relevance to the Olaf project.

1. Wang, Avery L. **An Industrial-Strength Audio Search Algorithm** (2003)
2. Six, Joren and Leman, Marc **[Panako - A Scalable Acoustic Fingerprinting System Handling Time-Scale and Pitch Modification](http://www.terasoft.com.tw/conf/ismir2014/proceedings/T048_122_Paper.pdf)** (2014)
3. Cano, Pedro and Batlle, Eloi and Kalker, Ton and Haitsma, Jaap **A Review of Audio Fingerprinting** (2005)
4. Arzt, Andreas and Bock, Sebastian and Widmer, Gerhard **Fast Identification of Piece and Score Position via Symbolic Fingerprinting** (2012)
5. Fenet, Sebastien and Richard, Gael and Grenier, Yves **A Scalable Audio Fingerprint Method with Robustness to Pitch-Shifting** (2011)
6. Ellis, Dan and Whitman, Brian and Porter, Alastair **Echoprint - An Open Music Identification Service** (2011)
7. Sonnleitner, Reinhard and Widmer, Gerhard **Quad-based Audio Fingerprinting Robust To Time And Frequency Scaling** (2014)
8. Sonnleitner, Reinhard and Widmer, Gerhard **[Robust Quad-Based Audio Fingerprinting](http://dx.doi.org/10.1109/TASLP.2015.2509248)** (2015)

The programming style of Olaf attempts to use an OOP inspired way to organize code and divide responsibilities and interfaces. For more information see on this style consult this document about [OOP in C](https://www.state-machine.com/doc/AN_OOP_in_C.pdf). Also of interest is the [Modern C book by Jens Gustedt](https://modernc.gforge.inria.fr/).

## Credits

* [PFFFT](https://bitbucket.org/jpommier/pffft/src/default/) a pretty fast FFT library. BSD license
* [LMDB](https://symas.com/lmdb/) [Lightning Memory-Mapped Database](https://en.wikipedia.org/wiki/Lightning_Memory-Mapped_Database), a fast key value store with a permissive software license (the OpenLDAP Public License) by Howard Chu.
* [Hash table](https://github.com/fragglet/c-algorithms) and dequeue by Simon Howard, ISC lisence
* [libsamplerate-js](https://github.com/aolsenjazz/libsamplerate-js) the browser based version of Olaf uses a WASM build of an audio resampling library [SRC](http://www.mega-nerd.com/SRC/) which is BSD licensed. `libsamplerate-js` is MIT licensed.

Olaf by Joren Six at IPEM, Ghent University.