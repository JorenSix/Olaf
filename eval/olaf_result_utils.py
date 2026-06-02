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

"""Utilities to deal with Olaf's CSV query output.

Due to threading the CSV output is likely to be scrambled: lines of
simultaneous queries are interleaved. This script can sort the lines.

    cat result_output.csv | python3 eval/olaf_result_utils.py sort

Results can be filtered for a minimum duration. Short duration results can be
false positives.

    cat result_output.csv | python3 eval/olaf_result_utils.py filter

Subsequent matching fragments can be merged with the merge command. If
fragments of 30 seconds are used and second 0-30 match with a reference item
and also 30-60 match with the same reference, the result lines are merged:

    cat result_output.csv | python3 eval/olaf_result_utils.py merge
    # verify with:
    nl result_output.csv
    cat result_output.csv | python3 eval/olaf_result_utils.py merge | nl

To verify false or true positives it is of interest to listen to the matches.
The check command cuts the matching parts of the query and reference into wav
files for inspection. Here a random selection of 10 results are checked:

    cat result_output.csv | sort -R | head | python3 eval/olaf_result_utils.py check

The utilities can be combined to filter, sort and check:

    olaf query --threads 20 --fragmented music_directory > result_output.csv
    cat result_output.csv | python3 eval/olaf_result_utils.py filter | \
        python3 eval/olaf_result_utils.py sort | sort -R | head | \
        python3 eval/olaf_result_utils.py check

Stdlib only; requires ffmpeg on PATH for the `check` command.
"""

import os
import subprocess
import sys

MIN_DURATION_IN_SECONDS = 5
MIN_MATCH_SCORE = 13
FRAGMENT_DURATION_IN_SECONDS = 30


class OlafResultLine:
    """One CSV line of `olaf query` output (11 comma-separated fields)."""

    def __init__(self, line):
        data = [p.strip() for p in line.split(",")]
        self.valid = len(data) == 11 and data[4].isdigit()
        if self.valid:
            self.index = int(data[0])
            self.total = int(data[1])
            self.query = data[2]
            self.query_offset = float(data[3])
            self.match_count = int(data[4])
            self.query_start = float(data[5])
            self.query_stop = float(data[6])
            self.ref_path = data[7]
            self.ref_id = data[8]
            self.ref_start = float(data[9])
            self.ref_stop = float(data[10])
        self.empty_match = self.valid and self.match_count == 0

    def __str__(self):
        return (
            f"{self.index} , {self.total} , {self.query} , {self.query_offset} , "
            f"{self.match_count} , {self.query_start} , {self.query_stop} , "
            f"{self.ref_path} , {self.ref_id} , {self.ref_start} , {self.ref_stop}"
        )


def store_audio_part(in_audio_file, in_offset, duration, out_audio_file):
    subprocess.run(
        [
            "ffmpeg", "-hide_banner", "-y", "-loglevel", "panic",
            "-i", in_audio_file,
            "-ss", str(in_offset), "-t", str(duration),
            "-ac", "1", out_audio_file,
        ]
    )


def result_line_to_wav(folder, duration, result_line):
    line = OlafResultLine(result_line)
    if not line.valid:
        sys.stderr.write(f"Invalid line: '{result_line}'\n")
        return

    # If no duration is given use the match duration.
    if duration is None:
        duration = line.query_stop - line.query_start

    # Find the query, first as given, then in the ref folder, then in `folder`.
    query = line.query
    if not os.path.exists(query):
        query = os.path.join(os.path.dirname(line.ref_path), line.query)
    if not os.path.exists(query) and folder:
        query = os.path.join(folder, line.query)

    if os.path.exists(query):
        q_base = os.path.splitext(os.path.basename(query))[0]
        r_base = os.path.splitext(os.path.basename(line.ref_path))[0]
        out_name = f"{q_base}_{r_base}.wav"
        store_audio_part(query, line.query_offset + line.query_start, duration, out_name)
    else:
        sys.stderr.write(f"Could not find query file {query}\n")

    if os.path.exists(line.ref_path):
        r_base = os.path.splitext(os.path.basename(line.ref_path))[0]
        q_base = os.path.splitext(os.path.basename(query))[0]
        out_name = f"{r_base}_{q_base}.wav"
        store_audio_part(line.ref_path, line.ref_start, duration, out_name)
    else:
        sys.stderr.write(f"Could not find ref file {line.ref_path}\n")


def valid_lines(text):
    for raw in text.split("\n"):
        line = OlafResultLine(raw)
        if line.valid:
            yield line


def cmd_sort():
    lines = list(valid_lines(sys.stdin.read()))
    lines.sort(key=lambda l: (l.query, l.query_offset, -l.match_count, l.query_start))
    for l in lines:
        print(l)


def cmd_filter(argv):
    min_duration = float(argv[1]) if len(argv) > 1 else MIN_DURATION_IN_SECONDS
    for l in valid_lines(sys.stdin.read()):
        name_ok = (
            os.path.basename(l.query).startswith("MN")
            and os.path.basename(l.ref_path).startswith("MN")
        )
        diff_ok = abs(l.query_start - l.ref_start) > 100
        time_ok = l.query_start > 100 and l.ref_start < 40
        duration_ok = (l.query_stop - l.query_start) > min_duration
        match_count_ok = l.match_count > MIN_MATCH_SCORE
        if duration_ok and match_count_ok and name_ok and diff_ok and time_ok:
            print(l)


def cmd_merge():
    groups = {}
    for l in valid_lines(sys.stdin.read()):
        key = "-_-".join([
            os.path.splitext(os.path.basename(l.query))[0],
            os.path.splitext(os.path.basename(l.ref_path))[0],
        ])
        groups.setdefault(key, []).append(l)

    for lines in groups.values():
        # Sort by offset then best match; keep only the best match per offset.
        lines.sort(key=lambda l: (l.query_offset, -l.match_count, l.query_start))
        seen = set()
        deduped = []
        for l in lines:
            if l.query_offset in seen:
                continue
            seen.add(l.query_offset)
            deduped.append(l)
        lines = deduped

        # Merge matches whose offsets form an uninterrupted sequence.
        seq = []
        prev_query_offset = -1
        for l in lines:
            if prev_query_offset < 0:
                seq.append(l)
            elif (prev_query_offset + FRAGMENT_DURATION_IN_SECONDS) == l.query_offset:
                seq.append(l)
            else:
                seq[0].match_count = sum(sl.match_count for sl in seq)
                seq[0].query_stop = seq[-1].query_stop
                seq[0].ref_stop = seq[-1].ref_stop
                print(seq[0])
                seq = [l]
            prev_query_offset = l.query_offset
            # Make query time absolute, not relative vs offset.
            l.query_start = l.query_offset + l.query_start
            l.query_stop = l.query_offset + l.query_stop
            l.query_offset = 0

        seq[0].match_count = sum(sl.match_count for sl in seq)
        seq[0].query_stop = seq[-1].query_stop
        seq[0].ref_stop = seq[-1].ref_stop
        print(seq[0])


def cmd_check(argv):
    duration = float(argv[1]) if len(argv) > 1 and argv[1] else None
    folder = argv[2] if len(argv) > 2 else None
    for result_line in sys.stdin.read().split("\n"):
        print(result_line)
        result_line_to_wav(folder, duration, result_line)


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else None
    if command == "sort":
        cmd_sort()
    elif command == "filter":
        cmd_filter(sys.argv[1:])
    elif command == "merge":
        cmd_merge()
    elif command == "check":
        cmd_check(sys.argv[1:])
    else:
        sys.stderr.write("Usage: olaf_result_utils.py {sort|filter|merge|check}\n")
        sys.exit(1)


if __name__ == "__main__":
    main()
