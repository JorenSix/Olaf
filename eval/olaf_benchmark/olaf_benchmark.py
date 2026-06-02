#!/usr/bin/env python3

# Olaf: Overly Lightweight Acoustic Fingerprinting
# Copyright (C) 2019-2025  Joren Six
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

"""Store/query throughput benchmark for Olaf.

Given a folder of mp3 files this tool indexes the collection in a doubling sweep
(64, 128, 256, ... files) and, at each step, measures how long it takes to
cache+store the new batch and to run a fixed set of queries. It prints one CSV
row per step with the indexed song count, the total indexed duration, and the
user/sys/real CPU times of the store and query phases.

Faithful port of the historical eval/olaf_benchmark/olaf_benchmark.rb. Requires
only `olaf` and `ffmpeg` on PATH; no third-party Python dependencies.
"""

import math
import os
import random
import re
import subprocess
import sys
import time

PROC_THREADS = 92
QUERY_FILE_SIZE_IN = 35
QUERY_FILE_SIZE_OUT = 15

AUDIO_FILE_GLOB_PATTERN = "**/*mp3"
START_SIZE = 64

RND = random.Random(0)


class Benchmark:
    """Captured CPU/wall times for a block, mirroring Ruby's Benchmark.measure.

    Reported fields, in order: user CPU, system CPU, the children user+sys CPU
    (Ruby's third "total" column), and real (wall-clock) time.
    """

    def __init__(self, user_cpu, sys_cpu, child_cpu, real_time):
        self.user_cpu = user_cpu
        self.sys_cpu = sys_cpu
        self.child_cpu = child_cpu
        self.real_time = real_time

    def fields(self):
        return [self.user_cpu, self.sys_cpu, self.child_cpu, self.real_time]


def measure(fn):
    """Run fn, returning a Benchmark of the elapsed CPU (incl. children) + wall time."""
    before = os.times()
    wall_before = time.monotonic()
    fn()
    wall_after = time.monotonic()
    after = os.times()
    user_cpu = (after.children_user - before.children_user)
    sys_cpu = (after.children_system - before.children_system)
    return Benchmark(user_cpu, sys_cpu, user_cpu + sys_cpu, wall_after - wall_before)


def files_to_list(files, filename):
    with open(filename, "w") as f:
        f.write("\n".join(files) + "\n")


def total_duration_seconds():
    """Parse the 'Total duration (s): <n>' line out of `olaf stats`."""
    stats = subprocess.run(
        ["olaf", "stats"], capture_output=True, text=True
    ).stdout
    m = re.search(r"Total duration .s...(.*)", stats)
    if not m:
        return 0.0
    try:
        return float(m.group(1).strip())
    except ValueError:
        return 0.0


def main():
    if len(sys.argv) < 2:
        sys.stderr.write("Folder 'None' should exist.\n")
        sys.exit(0)

    folder = sys.argv[1]
    if not os.path.isdir(folder):
        sys.stderr.write(f"Folder '{folder}' should exist.\n")
        sys.exit(0)

    import glob

    audio_files = glob.glob(os.path.join(folder, AUDIO_FILE_GLOB_PATTERN), recursive=True)

    if not audio_files:
        sys.stderr.write(f"No mp3 files found in '{folder}'.\n")
        sys.exit(0)

    times_two = int(math.log(len(audio_files)) / math.log(2))

    RND.shuffle(audio_files)

    query_selection_in = audio_files[0:QUERY_FILE_SIZE_IN]
    query_selection_out = audio_files[len(audio_files) - QUERY_FILE_SIZE_OUT:]

    start_index = 0
    stop_index = START_SIZE

    print(
        "songs, seconds, store_user_cpu, store_sys_cpu, store_sys_us_cpu, "
        "store_real_time, query_user_cpu, query_sys_cpu, query_user_sys_cpu, "
        "query_real_time"
    )

    while stop_index <= (1 << times_two):
        selection = audio_files[start_index:stop_index]

        progress_filename = f"{start_index}-{stop_index - 1}_cache_progress.txt"
        list_filename = f"{start_index}-{stop_index - 1}_store_list.txt"
        files_to_list(selection, list_filename)

        def do_store():
            with open(progress_filename, "w") as out, open(
                f"stderr_{progress_filename}", "w"
            ) as err:
                subprocess.run(
                    ["olaf", "cache", list_filename, "-n", str(PROC_THREADS)],
                    stdout=out,
                    stderr=err,
                )
            with open(os.devnull, "w") as devnull:
                subprocess.run(["olaf", "store_cached"], stdout=devnull)

        store_times = measure(do_store)

        seconds = total_duration_seconds()

        queries = query_selection_in + query_selection_out
        files_to_list(queries, "list.txt")

        def do_query():
            with open(os.devnull, "w") as devnull:
                subprocess.run(
                    ["olaf", "query", "list.txt"], stdout=devnull, stderr=devnull
                )

        query_times = measure(do_query)

        row = [stop_index, seconds] + store_times.fields() + query_times.fields()
        print(", ".join(str(x) for x in row))

        start_index = stop_index
        stop_index = start_index * 2


if __name__ == "__main__":
    main()
