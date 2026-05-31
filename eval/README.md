# Olaf - Evaluation & Benchmarking

The tests check **whether Olaf works**. The evaluation verifies **how well** Olaf works. The benchmark checks **how fast** Olaf works and how it deals with scalability and resources. There are a few evaluation and benchmarking scripts available for Olaf. This text describes each script.

## Benchmark index size - **how fast** does Olaf run?

The benchmark script stores a large amount of audio in an index and keeps the time it takes to store the audio. Each time the size of the index is doubled a number of queries run to check the time it takes to query the index.

With the script a folder of audio files is stored and it is registered how long it takes to store 64, 128, 256, 512,... files. If run with the [FMA full](https://github.com/mdeff/fma) dataset a total of more than 200 days of audio are stored at a rate of just under 2000 times real-time with a 96 CPU-core system. An interpretation of the graph is that indexing remains linear on larger datasets. At every doubling of the database the [query performance](./eval/olaf_benchmark/olaf_benchmark_query.svg) is also checked. Run the benchmark yourself:

The absolute values might differ significantly from one machine to another and are not that relevant. The fact that store speed and query speed do not halve each time the index size doubles is relevant: this shows that the system is scalable. This relatively limited effect of index size is expected to be similar on all machines.

<div align="center">
<img src="./olaf_benchmark/olaf_benchmark.svg" alt="Benchmark results for Olaf" />
<br>
<small><strong>Fig.</strong> This reports the time it takes to store 200 days of audio (or reference 10^7 is about 100 days of audio) The log-log linear relation means that the speed of storing audio is not slower for larger database.</small>
</div>

<div align="center">
<img src="./olaf_benchmark/olaf_benchmark_query.svg" alt="Benchmark results for Olaf" />
<br>
<small><strong>Fig.</strong> This reports the time it takes to query audio. Each time the same audio is queried. This shows that a query goes slower when the index is larger but, crucially, the slowdown is not proportional to the increase in index size: this indicates a level of scalability.</small>
</div>

## Benchmark - **how fast** does Olaf run vs Panako?

Olaf shares many similarities with [Panako](https://github.com/JorenSix/Panako). A similar algorithm is implemented. There are a few key differences. Panako is implemented in Java, is multi-threaded and is not conservative with memory use. Panako also contains an additional algorithm which is robust against speed changes.

There is a script which compares Olaf run times with Panako directly by storing items in an empty database and now and then run a query. The times it takes to store and run queries is reported and compared. Run the script with a (large) collection of music (e.g. the free music archive):

```bash
ruby eval/olaf_vs_panako.rb /home/user/music
```

Note that the script has a couple of assumptions and limitations:

* the script does not check the result of the commands
* the indexes of both systems should be empty at the start, this is not checked by the script
* it assumes both Panako and Olaf are installed correctly on the system

<div align="center">
<img src="./olaf_vs_panako/olaf_vs_panako_store.svg" alt="Olaf vs Panako store times" />
<br>
<small><strong>Fig.</strong> The time it takes to store the same audio files in Panako and Olaf. Times are reported in s/s. A value of 250 means that the system can store 250 seconds of audio in a single second. Note that the storage speed of Olaf is about double that of Panako. This is mainly due to an algorithmic optimization in Olaf in the max filtering step.</small>
</div>

<div align="center">
<img src="./olaf_vs_panako/olaf_vs_panako_query.svg" alt="Olaf vs Panako query times" />
<br>
<small><strong>Fig.</strong> The time it takes to query the same audio files in Panako and Olaf. The time is reported in s/s. A value of 250 means that it takes e.g. 1 second to query for 250s of audio. The difference is mainly due to an algorithmic optimization in Olaf in the max filtering step.</small>
</div>

## Benchmark - How much memory does Olaf use?

A script is provided to measure memory use when running a 20 second query. To see the influence of the size of the index the memory use is measured after every 10 stored files. The size of the index is expressed in seconds. The memory use is reported in kilobytes.

The script needs access to a folder with `mp3` or other audio files. It can be ran like this:

```bash
ruby eval/olaf_memory_use.rb /User/Music
```

The script assumes that the installed version of Olaf uses the same index as `bin/olaf_c` which is used for memory consumption.

To measure memory use, the macOS utility `/usr/bin/time` is employed. Similar utilities are available for Linux or other systems. To use the script on your system check and adapt the `memory_use` function accordingly.

The baseline memory of an 'empty' c program is subtracted from the reported values: only the memory use of Olaf is reported not that of the environment. On macOS this means that about one megabyte of memory is not reported! The following one-liner can be used to check the memory use to run an empty c program on macOS:

```bash
echo "int main(int argc, char** argv) { return 0; }" > t.c && gcc t.c && /usr/bin/time -l  ./a.out
```

<div align="center">
<img src="./olaf_memory_use/olaf_memory_use.svg" alt="Olaf memory use" />
<br>
<small><strong>Fig.</strong> Memory use of running a 20 second query with Olaf for several sizes of the index. On traditional computers a memory use of a few MB is negligible. This changes for embedded systems. The memory use of Olaf in that case is lower than 512kB since the index is smaller, the queries are shorter and no key-value store is used.</small>
</div>

Memory use is one thing, memory leaks another. To detect memory leaks the macOS `leaks` utility can be used in the following way:

```bash
leaks --atExit -- bin/olaf_c query dataset/raw/queries/olaf_audio_147199_115s-135s.raw 147199.mp3
```

This reports if any memory leaks are found and where these potentially originate. To detect leaks in all code paths other commands (store, delete) should be checked as well. On other systems similar utilities exist: on Linux [valgrind](https://valgrind.org/) is a possible alternative.

## Testing Olaf - check **whether Olaf works**

The first thing this checks is whether Olaf compiles correctly. Afterwards, a small dataset is indexed and some queries are fired. The result of the queries is evaluated for correctness. Also the memory version of Olaf is checked. To run this yourself, with Ruby, `ffmpeg` and `ffprobe` installed:

```bash
git clone https://github.com/JorenSix/Olaf
cd Olaf
make && make install
ruby eval/olaf_functional_tests.rb
```

Less interesting are the unit tests, these are mainly of interest for developing Olaf. The unit test can be compiled with `make test` and ran with `./bin/olaf_tests`.

### Evaluating Olaf - **how well** does Olaf recognize audio?

The recognition benchmark takes a folder of media files, indexes a fixed fraction of them (80% by default) and then cuts random short audio segments (5-10s) with `ffmpeg` and checks whether Olaf finds them back in the index. It reports a **recognition rate** (true-positive rate) and, optionally, a false-positive rate. This establishes a reproducible baseline to compare before and after tuning fingerprint or matcher parameters.

Each run is controlled: it rebuilds Olaf (`zig build -Doptimize=ReleaseFast`), writes a fixed configuration, and isolates the database in a temporary sandbox by overriding the `HOME` environment variable, so your real `~/.olaf` database is never touched. Only `ffmpeg`/`ffprobe` and Python 3 (standard library only) are required.

```bash
python3 eval/olaf_recognition_benchmark.py /folder/with/music
```

Useful options (see `--help` for the full list):

```
--index-fraction 0.8       fraction of files added to the index
--segments-per-file 1      random query segments cut per indexed file
--min-seg 5 --max-seg 10   segment length bounds in seconds
--negatives N              also cut N segments from held-out (non-indexed) files,
                           expected NOT to match (measures false positives)
--seed 42                  RNG seed for reproducible runs
--threads N                threads passed to olaf store/query
--skip-build               reuse the existing zig-out/bin/olaf instead of rebuilding
--keep-workdir             keep the temp sandbox for inspection
--csv results.csv          write per-segment results
--distortions LIST         apply SoX distortions to the positive query segments and
                           report a recognition rate per distortion (requires sox).
                           Comma list of flanger,band_passed,chorus,echo,tremolo,
                           fm_compressed, time_shift_{0_5,1,3}, pitch_shift_{0_5,1,3},
                           speed_up_{0_5,1,3}, or 'all'. Default: none (clean baseline).
--log results.log          write a DEBUG-level per-action log (every store, query and
                           sox invocation, with exit code, elapsed time and match count)
```

The fixed configuration lives in the `FIXED_CONFIG` dictionary at the top of the script (the Olaf defaults). To evaluate a recognition-rate change, edit a value there and re-run with the same `--seed`; the recognition rate is directly comparable. The result depends on the input audio but for clean re-encoded segments of music-like signals the recognition rate should be near `1.000`. Each modification gets a full confusion matrix — TPR (recall) with TP/FN, TNR (specificity) with FP/TN, precision (`P`), `F1`, mean match count (`mc`) and the time-accuracy check — followed by an `OVERALL` line that sums every cell:

```
none           TPR 1.000 (TP=16 FN=0)  TNR 1.000 (FP=0 TN=5)  P 1.000  F1 1.000  mc=53.4 | time 100ms: 1.000 (16/16, max err 0.007s)
OVERALL        TPR 1.000 (TP=16 FN=0)  TNR 1.000 (FP=0 TN=5)  P 1.000  F1 1.000  acc 1.000
```

#### Robustness to degraded audio (`--distortions`)

To measure how well Olaf recognizes audio that has been degraded, pass `--distortions`. Each segment is first cut clean (the `none` baseline), then a distorted sibling is produced with [SoX](http://sox.sourceforge.net/) for every requested effect and queried separately. Distortions are applied to **both** the positive segments and the held-out negatives, so every modification gets its own full confusion matrix: the positives drive TPR (does the degradation hurt recall?) while the distorted negatives drive TNR (does the degradation provoke a false positive?):

```bash
python3 eval/olaf_recognition_benchmark.py /folder/with/music --distortions all --log eval.log
```

```
none           TPR 1.000 (TP=16 FN=0)  TNR 1.000 (FP=0 TN=5)  P 1.000  F1 1.000  mc=53.4 | time 100ms: 1.000 (16/16, max err 0.007s)
flanger        TPR 0.688 (TP=11 FN=5)  TNR 1.000 (FP=0 TN=5)  P 1.000  F1 0.815  mc=16.4 | time 100ms: 0.818 (9/11, max err 26.802s)
band_passed    TPR 1.000 (TP=16 FN=0)  TNR 1.000 (FP=0 TN=5)  P 1.000  F1 1.000  mc=29.9 | time 100ms: 1.000 (16/16, max err 0.009s)
chorus         TPR 0.500 (TP=8 FN=8)   TNR 1.000 (FP=0 TN=5)  P 1.000  F1 0.667  mc=12.4 | time 100ms: 0.875 (7/8, max err 1.204s)
...
OVERALL        TPR 0.828 (TP=212 FN=44)  TNR 1.000 (FP=0 TN=80)  P 1.000  F1 0.906  acc 0.869
```

Each row is a confusion matrix for one modification: TPR (recall) with its TP/FN, TNR (specificity) with its FP/TN, precision (`P`), `F1`, mean match count (`mc`), and the time-accuracy check (fraction of correct hits whose reported position lands within 100 ms of the true cut offset). The time-axis distortions (`time_shift`, `speed_up`) scale the timeline, so large time errors there are expected. The `OVERALL` line sums every cell across all modifications and adds accuracy (`acc`).

The distortions are the active set from the historical Ruby evaluator (`flanger`, `band_passed` at 2000 Hz, `chorus`, `echo`, `tremolo`) plus `fm_compressed`, a multiband FM-broadcast processing chain, and three time-axis families at 0.5/1/3 %: `time_shift` (tempo change, pitch preserved), `pitch_shift` (pitch change, duration preserved) and `speed_up` (resample, both change). With `--distortions all` the negative query count grows from `--negatives N` to `N × (1 + number of distortions)`, since each negative is also distorted. The `--log` file records one line per store, query and sox action (command, exit code, elapsed time, and for queries the parsed match count), so a run is auditable and failures are diagnosable.