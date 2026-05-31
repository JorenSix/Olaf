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

"""Recognition-rate benchmark for Olaf.

Given a folder of media files this tool indexes a fixed fraction (default 80%)
of the files and then cuts random short audio segments (5-10s) with ffmpeg and
checks whether Olaf finds them back in the index. It reports a recognition rate
(true-positive rate) and a false-positive rate, establishing a reproducible
baseline that can be compared before and after tuning fingerprint/matcher
parameters.

Every run is controlled: it rebuilds Olaf (unless --skip-build), writes a fixed
configuration, and isolates the database in a temporary sandbox by overriding the
HOME environment variable, so the user's real ~/.olaf database is never touched.
"""

import argparse
import concurrent.futures
import csv
import json
import logging
import math
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
import time

log = logging.getLogger("olaf_recog")

# A true positive must also be reported at the right position: the source offset
# implied by the match (reference_start - query_start) must agree with where the
# segment was actually cut, within this tolerance (seconds).
TIME_TOLERANCE_S = 0.100

# Matches the suffix added in make_segment: _<start>s-<stop>s_<index>, plus an
# optional __<modification> added by apply_distortion, plus the extension.
SEGMENT_SUFFIX_RE = re.compile(r"_\d+s-\d+s_\d+(?:__[A-Za-z0-9_]+)?(\.[^.]+)?$")

# SoX distortions applied to positive query segments, recovered verbatim from
# the old eval/olaf_evaluation.rb (git show HEAD:eval/olaf_evaluation.rb:37-96).
# Each value is the list of sox effect arguments appended after "sox IN OUT".
# Order is preserved for stable per-modification reporting.
DISTORTIONS = {
    "flanger": ["flanger"],
    "band_passed": ["band", "2000"],
    "chorus": ["chorus", "0.7", "0.9", "55", "0.4", "0.25", "2", "-t"],
    "echo": ["echo", "0.8", "0.9", "500", "0.3"],
    "tremolo": ["tremolo", "8"],
    "fm_compressed": [
        # Resample to 44.1 kHz first: the broadcast chain's high-frequency sinc
        # filters (-17500) and lowpass (17801) exceed Nyquist on lower-rate
        # sources and sox aborts ("filter frequency must be less than
        # sample-rate / 2"). FM broadcast processing assumes CD-rate audio anyway.
        "rate", "44100",
        "gain", "-15", "sinc", "-b", "29", "-n", "100", "-8000", "mcompand",
        "0.005,0.1 -47,-40,-34,-34,-17,-33", "100",
        "0.003,0.05 -47,-40,-34,-34,-17,-33", "400",
        "0.000625,0.0125 -47,-40,-34,-34,-15,-33", "1600",
        "0.0001,0.025 -47,-40,-34,-34,-31,-31,-0,-30", "6400",
        "0,0.025 -38,-31,-28,-28,-0,-25",
        "gain", "15", "highpass", "22", "highpass", "22",
        "sinc", "-n", "255", "-b", "16", "-17500",
        "gain", "9", "lowpass", "-1", "17801",
    ],
}

# Time/pitch/speed distortions at 0.5%, 1% and 3%. Olaf's base algorithm is not
# robust to time-axis changes, so these probe how quickly recognition degrades.
#   time_shift_<p>: sox `tempo` changes duration but preserves pitch.
#   pitch_shift_<p>: sox `pitch` changes pitch (in cents) but preserves duration.
#   speed_up_<p>:    sox `speed` resamples, changing both pitch and duration.
# A factor of 1 + p/100 is faster/shorter; cents = 1200*log2(1 + p/100).
for _pct in (0.5, 1.0, 3.0):
    _factor = 1.0 + _pct / 100.0
    _cents = 1200.0 * math.log2(_factor)
    _tag = ("%g" % _pct).replace(".", "_")
    DISTORTIONS["time_shift_%s" % _tag] = ["tempo", "%.5f" % _factor]
    DISTORTIONS["pitch_shift_%s" % _tag] = ["pitch", "%.2f" % _cents]
    DISTORTIONS["speed_up_%s" % _tag] = ["speed", "%.5f" % _factor]

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OLAF_BINARY = os.path.join(REPO_ROOT, "zig-out", "bin", "olaf")

# Mirrors cli/olaf_cli_config.zig allowed_audio_file_extensions (case-insensitive).
ALLOWED_EXTENSIONS = {
    ".m4a", ".wav", ".mp4", ".wv", ".ape", ".ogg", ".mp3", ".flac", ".wma",
}

# Fixed configuration written into the sandbox. These are the Olaf defaults from
# cli/olaf_cli_config.zig:7-58. Edit values here to evaluate recognition-rate
# changes; db_folder/cache_folder resolve under the sandboxed HOME.
FIXED_CONFIG = {
    "db_folder": "~/.olaf/db/",
    "cache_folder": "~/.olaf/cache",
    "check_incoming_audio": True,
    "skip_duplicates": True,
    "fragment_duration_in_seconds": 30,
    "target_sample_rate": 16000,
    "allowed_audio_file_extensions": [
        ".m4a", ".wav", ".mp4", ".wv", ".ape", ".ogg", ".mp3", ".raw", ".flac", ".wma",
    ],
    "audio_block_size": 1024,
    "audio_step_size": 128,
    "bytes_per_audio_sample": 4,
    "max_event_points": 60,
    "event_point_threshold": 30,
    "sqrt_magnitude": False,
    "filter_size_frequency": 103,
    "filter_size_time": 24,
    "min_event_point_magnitude": 0.001,
    "max_event_point_usages": 10,
    "min_frequency_bin": 9,
    "verbose": False,
    "number_of_eps_per_fp": 3,
    "use_magnitude_info": False,
    "min_time_distance": 2,
    "max_time_distance": 33,
    "min_freq_distance": 1,
    "max_freq_distance": 128,
    "max_fingerprints": 300,
    "max_results": 50,
    "search_range": 5,
    "min_match_count": 6,
    "min_match_time_diff": 0,
    "keep_matches_for": 0,
    "print_result_every": 0,
    "max_db_collisions": 2000,
}


class Match:
    """Best match parsed from Olaf's `query --format json` output.

    The JSON is a single object per query with a `matches` array sorted by
    descending match_count; we keep the top entry. A match_count of 0 (or an
    empty array) means no match. Using JSON avoids the brittleness of splitting
    the CSV on commas, which also appear inside file paths.
    """

    __slots__ = ("valid", "match_count", "query_start", "ref_path", "ref_id",
                 "ref_start", "ref_stop")

    def __init__(self, valid=False, match_count=0, query_start=0.0, ref_path="",
                 ref_id="", ref_start=0.0, ref_stop=0.0):
        self.valid = valid
        self.match_count = match_count
        self.query_start = query_start
        self.ref_path = ref_path
        self.ref_id = ref_id
        self.ref_start = ref_start
        self.ref_stop = ref_stop

    @property
    def is_hit(self):
        return self.valid and self.match_count > 0


def _to_float(value):
    try:
        return float(value)
    except (ValueError, TypeError):
        return 0.0


def run(cmd, env=None, capture=False, check=True):
    """Run a command, returning stdout when capture=True."""
    result = subprocess.run(
        cmd,
        env=env,
        check=False,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
        text=True,
    )
    if check and result.returncode != 0:
        msg = result.stderr if capture and result.stderr else ""
        raise RuntimeError(
            "Command failed (exit {}): {}\n{}".format(result.returncode, " ".join(cmd), msg)
        )
    return result.stdout if capture else None


def ffprobe_duration(path):
    """Duration in seconds, or 0.0 on failure. Mirrors olaf_evaluation.rb:16."""
    try:
        out = run(
            [
                "ffprobe", "-i", path,
                "-show_entries", "format=duration",
                "-v", "quiet", "-of", "csv=p=0",
            ],
            capture=True,
            check=False,
        )
        return _to_float((out or "").strip())
    except FileNotFoundError:
        raise RuntimeError("ffprobe not found on PATH; ffmpeg/ffprobe are required.")


def cut_segment(src, start, length, out_path):
    """Cut a mono segment with ffmpeg. Mirrors eval/olaf_result_utils.rb:54.

    -ss before -i is fast, accurate input seeking. -vn drops any video/cover-art
    stream (embedded album art makes ffmpeg fail when it tries to transcode the
    image into the output container).

    Returns True when a valid, non-empty segment was produced. Some source files
    advertise a longer duration than they can actually decode (truncated/corrupt
    tails); cutting from those regions yields an empty file. We validate the
    result and return False instead of crashing, so the run can skip it.
    """
    run(
        [
            "ffmpeg", "-hide_banner", "-y", "-loglevel", "error",
            "-ss", "{:.3f}".format(start), "-i", src, "-t", "{:.3f}".format(length),
            "-vn", "-ac", "1", out_path,
        ],
        check=False,
        capture=True,
    )
    if not os.path.exists(out_path) or os.path.getsize(out_path) < 1024:
        return False
    return ffprobe_duration(out_path) > 0.0


def apply_distortion(name, in_path, out_path):
    """Apply a SoX distortion to a segment. Returns True on a valid output.

    Validates the result like cut_segment (exists, non-trivial size, probes a
    positive duration) so a failed effect skips that variant instead of crashing.
    """
    effect = DISTORTIONS[name]
    result = olaf_action(
        "sox:" + name, ["sox", in_path, out_path, *effect], capture=True, check=False
    )
    if result.returncode != 0:
        return False
    if not os.path.exists(out_path) or os.path.getsize(out_path) < 1024:
        return False
    return ffprobe_duration(out_path) > 0.0


def olaf_action(kind, cmd, env=None, capture=True, check=False):
    """Run an external action (olaf store/query, sox, ...) with per-action logging.

    Logs the command before running and the exit code + elapsed time after, at
    DEBUG. Returns the CompletedProcess so callers can inspect stdout/returncode.
    """
    log.debug("%s: running: %s", kind, " ".join(cmd))
    start = time.perf_counter()
    result = subprocess.run(
        cmd,
        env=env,
        check=False,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
        text=True,
    )
    elapsed = time.perf_counter() - start
    log.debug("%s: exit=%d elapsed=%.3fs", kind, result.returncode, elapsed)
    if check and result.returncode != 0:
        msg = (result.stderr or "") if capture else ""
        raise RuntimeError(
            "Command failed (exit {}): {}\n{}".format(result.returncode, " ".join(cmd), msg)
        )
    return result


def names_match(segment_basename, ref_path):
    """True when ref_path corresponds to the source the segment was cut from.

    Mirrors olaf_evaluation.rb file_names_match?: strip the trailing
    _<start>s-<stop>s_<index> marker (and an optional __<modification> suffix
    added for distorted variants) from the segment name and check the reference
    basename contains the remaining stem.
    """
    stem = SEGMENT_SUFFIX_RE.sub("", segment_basename)
    ref_base = os.path.basename(ref_path)
    return stem != "" and stem in ref_base


def draw_attempts(rng, args, duration, n=4):
    """Pre-draw n (start, length) candidates for cutting a segment.

    Done serially against the shared RNG so runs stay reproducible for a given
    --seed even though the actual cutting runs concurrently. Later attempts bias
    toward the start of the file, where audio is most likely intact when a
    corrupt/truncated tail makes a later offset undecodable.
    """
    attempts = []
    for attempt in range(n):
        length = min(rng.uniform(args.min_seg, args.max_seg), duration)
        upper = max(0.0, duration - length)
        if attempt > 0:
            upper = upper / (2 ** attempt)
        start = rng.uniform(0, upper)
        attempts.append((start, length))
    return attempts


def rates(tp, fn, fp, tn):
    """Derived rates from a confusion matrix. Missing denominators yield None."""
    def div(num, den):
        return (num / den) if den else None
    tpr = div(tp, tp + fn)          # recall / sensitivity
    tnr = div(tn, tn + fp)          # specificity
    precision = div(tp, tp + fp)
    f1 = None
    if precision is not None and tpr is not None and (precision + tpr) > 0:
        f1 = 2 * precision * tpr / (precision + tpr)
    accuracy = div(tp + tn, tp + tn + fp + fn)
    return {"tpr": tpr, "tnr": tnr, "precision": precision, "f1": f1, "accuracy": accuracy}


def discover_files(folder):
    files = []
    for root, _dirs, names in os.walk(folder):
        for name in names:
            ext = os.path.splitext(name)[1].lower()
            if ext in ALLOWED_EXTENSIONS:
                files.append(os.path.abspath(os.path.join(root, name)))
    return files


def git_commit():
    try:
        out = run(["git", "-C", REPO_ROOT, "rev-parse", "--short", "HEAD"], capture=True, check=False)
        return (out or "").strip() or "unknown"
    except Exception:
        return "unknown"


def olaf_env(work_dir):
    env = dict(os.environ)
    env["HOME"] = work_dir
    return env


def parse_first_match(query_output):
    """Parse Olaf's JSON query output and return the best Match (or None).

    Olaf prints one JSON object (`query --format json`); `matches` is sorted by
    descending match_count. Returns a Match for the top entry, an invalid Match
    when the array is empty, or None when the output is not parseable JSON.
    """
    text = (query_output or "").strip()
    if not text:
        return None
    try:
        obj = json.loads(text)
    except json.JSONDecodeError:
        return None
    matches = obj.get("matches") or []
    if not matches:
        return Match(valid=True, match_count=0)
    top = matches[0]
    return Match(
        valid=True,
        match_count=int(top.get("match_count", 0)),
        query_start=_to_float(top.get("query_start", 0.0)),
        ref_path=str(top.get("path", "")),
        ref_id=str(top.get("match_identifier", "")),
        ref_start=_to_float(top.get("reference_start", 0.0)),
        ref_stop=_to_float(top.get("reference_stop", 0.0)),
    )


def build_olaf():
    print("Building olaf (zig build -Doptimize=ReleaseFast)...", flush=True)
    run(["zig", "build", "-Doptimize=ReleaseFast"], check=True)
    if not os.path.exists(OLAF_BINARY):
        raise RuntimeError("Build finished but binary not found at {}".format(OLAF_BINARY))


def main():
    parser = argparse.ArgumentParser(description="Olaf recognition-rate benchmark.")
    parser.add_argument("media_folder", help="Folder with media files.")
    parser.add_argument("--index-fraction", type=float, default=0.8,
                        help="Fraction of files added to the index (default 0.8).")
    parser.add_argument("--segments-per-file", type=int, default=1,
                        help="Random query segments cut per indexed file (default 1).")
    parser.add_argument("--min-seg", type=float, default=5.0,
                        help="Minimum segment length in seconds (default 5).")
    parser.add_argument("--max-seg", type=float, default=10.0,
                        help="Maximum segment length in seconds (default 10).")
    parser.add_argument("--negatives", type=int, default=0,
                        help="Segments cut from held-out files, expected NOT to match.")
    parser.add_argument("--seed", type=int, default=42, help="RNG seed (default 42).")
    parser.add_argument("--threads", type=int, default=max(1, (os.cpu_count() or 1) - 2),
                        help="Worker threads for ffmpeg/sox cutting and olaf "
                             "store/query (default: CPUs - 2, minimum 1).")
    parser.add_argument("--skip-build", action="store_true",
                        help="Use the existing binary instead of rebuilding.")
    parser.add_argument("--keep-workdir", action="store_true",
                        help="Do not delete the temp sandbox (for debugging).")
    parser.add_argument("--csv", help="Write per-segment results to this CSV file.")
    parser.add_argument("--distortions", default="",
                        help="Comma list of SoX distortions to apply to positive query "
                             "segments, or 'all'. Choices: {}. Requires sox.".format(
                                 ",".join(DISTORTIONS)))
    parser.add_argument("--log", dest="log_path",
                        help="Write a DEBUG-level per-action log (every store/query/sox) "
                             "to this file.")
    args = parser.parse_args()

    # Logging: console at INFO, optional file handler at DEBUG.
    log.setLevel(logging.DEBUG)
    log.propagate = False
    console = logging.StreamHandler()
    console.setLevel(logging.INFO)
    console.setFormatter(logging.Formatter("%(message)s"))
    log.addHandler(console)
    if args.log_path:
        file_handler = logging.FileHandler(args.log_path, mode="w")
        file_handler.setLevel(logging.DEBUG)
        file_handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
        log.addHandler(file_handler)

    if not os.path.isdir(args.media_folder):
        sys.exit("Error: '{}' is not a directory.".format(args.media_folder))
    if args.min_seg <= 0 or args.max_seg < args.min_seg:
        sys.exit("Error: require 0 < --min-seg <= --max-seg.")
    if not (0 < args.index_fraction < 1):
        sys.exit("Error: --index-fraction must be between 0 and 1.")

    # Resolve requested distortions.
    if args.distortions.strip().lower() == "all":
        distortions = list(DISTORTIONS)
    elif args.distortions.strip():
        distortions = [d.strip() for d in args.distortions.split(",") if d.strip()]
        unknown = [d for d in distortions if d not in DISTORTIONS]
        if unknown:
            sys.exit("Error: unknown distortion(s) {}. Valid: {}".format(
                ", ".join(unknown), ", ".join(DISTORTIONS)))
    else:
        distortions = []
    if distortions and not shutil.which("sox"):
        sys.exit("Error: --distortions requested but 'sox' was not found on PATH.")

    rng = random.Random(args.seed)

    if args.skip_build:
        if not os.path.exists(OLAF_BINARY):
            sys.exit("Error: --skip-build set but binary missing at {}".format(OLAF_BINARY))
    else:
        build_olaf()

    commit = git_commit()

    # Discover and filter files.
    all_files = discover_files(args.media_folder)
    rng.shuffle(all_files)
    usable = []
    for f in all_files:
        if ffprobe_duration(f) >= args.max_seg:
            usable.append(f)
    if len(usable) < 2:
        sys.exit("Error: need at least 2 files longer than {}s; found {}.".format(
            args.max_seg, len(usable)))

    n_index = max(1, math.ceil(args.index_fraction * len(usable)))
    n_index = min(n_index, len(usable) - 1)  # keep at least one held-out file
    index_files = usable[:n_index]
    holdout_files = usable[n_index:]

    work_dir = tempfile.mkdtemp(prefix="olaf_recog_")
    try:
        # Sandbox + fixed config.
        olaf_home = os.path.join(work_dir, ".olaf")
        os.makedirs(olaf_home, exist_ok=True)
        with open(os.path.join(olaf_home, "olaf_config.json"), "w") as fh:
            json.dump(FIXED_CONFIG, fh, indent=2)
        env = olaf_env(work_dir)
        segments_dir = os.path.join(work_dir, "segments")
        os.makedirs(segments_dir, exist_ok=True)

        # Index the 80% reference set with a multithreaded store: pass every file
        # to a single `olaf store --threads N` call, which fans the work out over
        # a thread pool. The whole batch is one logged store action.
        log.info("Indexing %d reference files (%d threads)...",
                 len(index_files), args.threads)
        store_cmd = [OLAF_BINARY, "store", "--threads", str(args.threads)]
        store_cmd += index_files
        store_result = olaf_action(
            "store ({} files)".format(len(index_files)), store_cmd, env=env, check=False)
        if store_result.returncode != 0:
            raise RuntimeError("olaf store failed (exit {}):\n{}".format(
                store_result.returncode, store_result.stderr or ""))
        stored = len(index_files)

        # Plan all segment work serially so the RNG is consumed deterministically
        # (random module is not thread-safe and we want reproducible runs for a
        # given --seed). Each plan item holds the source, label, index, and the
        # pre-drawn (start, length) candidates per retry attempt. The actual
        # ffmpeg/sox work is then done concurrently below.
        plan = []  # (src, expected, index, [(start, length), ...])
        idx = 0
        for src in index_files:
            duration = ffprobe_duration(src)
            for _ in range(args.segments_per_file):
                plan.append((src, True, idx, draw_attempts(rng, args, duration)))
                idx += 1
        for _ in range(args.negatives):
            src = holdout_files[rng.randrange(len(holdout_files))]
            duration = ffprobe_duration(src)
            plan.append((src, False, idx, draw_attempts(rng, args, duration)))
            idx += 1

        def make_segment(item):
            """Cut one valid clean segment, retrying at earlier offsets if the
            source tail is undecodable, then derive any requested distorted
            variants. Returns a list of segment tuples (empty if all cuts fail).
            Pure per-item work: reads no shared state, mutates none."""
            src, expected, index, attempts = item
            stem, ext = os.path.splitext(os.path.basename(src))
            for start, length in attempts:
                seg_name = "{}_{:.0f}s-{:.0f}s_{}{}".format(stem, start, start + length, index, ext)
                seg_path = os.path.join(segments_dir, seg_name)
                if not cut_segment(src, start, length, seg_path):
                    continue
                # cut_start is the precise source offset the segment begins at;
                # used to verify Olaf reports the match at the right position.
                out = [(seg_path, seg_name, src, expected, "none", start)]
                # Distort both positives (per-mod TPR) and negatives (per-mod
                # FP/TN, i.e. does a degradation cause false matches?). Variants
                # share the same cut_start (sox effects don't move the segment's
                # start relative to the source).
                base_no_ext = seg_name[: -len(ext)] if ext else seg_name
                for mod in distortions:
                    dist_name = "{}__{}{}".format(base_no_ext, mod, ext)
                    dist_path = os.path.join(segments_dir, dist_name)
                    if apply_distortion(mod, seg_path, dist_path):
                        out.append((dist_path, dist_name, src, expected, mod, start))
                    else:
                        log.warning("  could not apply %s to %s", mod, seg_name)
                return out
            return []

        # Cut (and distort) segments concurrently: ffmpeg/sox are external
        # processes, so a thread pool overlaps their run times.
        log.info("Cutting %d segments across %d workers...", len(plan), args.threads)
        if args.threads > 1 and len(plan) > 1:
            with concurrent.futures.ThreadPoolExecutor(max_workers=args.threads) as pool:
                results = list(pool.map(make_segment, plan))
        else:
            results = [make_segment(item) for item in plan]

        segments = []
        skipped = 0
        for item, produced in zip(plan, results):
            if produced:
                segments.extend(produced)
            else:
                skipped += 1
                src, expected, _index, _attempts = item
                kind = "" if expected else "negative "
                log.warning("  could not cut a valid %ssegment from %s",
                            kind, os.path.basename(src))

        log.info("Querying %d segments across %d workers (%d skipped)...",
                 len(segments), args.threads, skipped)

        def query_segment(seg):
            """Query one segment in its own subprocess and return a result row.

            Each query is single-threaded (one short segment gains nothing from
            olaf's internal threads); parallelism comes from running many of
            these subprocesses concurrently in the thread pool below. Returns a
            dict; tallying happens single-threaded after all results are in, so
            no shared counters are mutated here.
            """
            seg_path, seg_name, src, expected, modification, cut_start = seg
            query_cmd = [OLAF_BINARY, "query", "--format", "json", seg_path]
            # A query that fails to process is treated as "no match" rather than
            # aborting the whole run.
            result = olaf_action(
                "query " + os.path.basename(seg_path), query_cmd, env=env, check=False)
            match = parse_first_match(result.stdout or "")
            is_hit = match is not None and match.is_hit
            correct_ref = is_hit and names_match(seg_name, match.ref_path)

            # Position check: the match's first hit sits at query_start within the
            # segment and reference_start within the source, so the source offset
            # the segment begins at is (reference_start - query_start). Compare to
            # the actual cut_start. Only meaningful for a correct-reference hit.
            time_error = None
            time_ok = False
            if correct_ref:
                implied_cut_start = match.ref_start - match.query_start
                time_error = abs(implied_cut_start - cut_start)
                time_ok = time_error <= TIME_TOLERANCE_S

            log.debug("query %s: match_count=%d ref=%s time_error=%s",
                      os.path.basename(seg_path),
                      match.match_count if match else 0,
                      os.path.basename(match.ref_path) if (match and match.valid) else "-",
                      "{:.3f}s".format(time_error) if time_error is not None else "-")
            return {
                "segment": seg_name,
                "source": os.path.basename(src),
                "modification": modification,
                "expected_match": expected,
                "hit": is_hit,
                "correct_ref": correct_ref,
                "time_ok": time_ok,
                "time_error_s": round(time_error, 4) if time_error is not None else "",
                "match_count": match.match_count if match else 0,
                "ref_path": match.ref_path if (match and match.valid) else "",
            }

        # Run queries concurrently, then tally sequentially to keep counters safe.
        rows = []
        if args.threads > 1 and len(segments) > 1:
            with concurrent.futures.ThreadPoolExecutor(max_workers=args.threads) as pool:
                rows = list(pool.map(query_segment, segments))
        else:
            rows = [query_segment(seg) for seg in segments]

        # Per-modification TP/FN tallies for positives; global FP/TN for negatives.
        # mod_time_ok counts the TPs whose reported position was also within
        # TIME_TOLERANCE_S of the actual cut; mod_time_err collects those errors.
        mod_tp = {}
        mod_fn = {}
        mod_fp = {}
        mod_tn = {}
        mod_mc = {}
        mod_time_ok = {}
        mod_time_err = {}
        for row in rows:
            modification = row["modification"]
            if row["expected_match"]:
                if row["hit"] and row["correct_ref"]:
                    mod_tp[modification] = mod_tp.get(modification, 0) + 1
                    mod_mc.setdefault(modification, []).append(row["match_count"])
                    if row["time_ok"]:
                        mod_time_ok[modification] = mod_time_ok.get(modification, 0) + 1
                    if row["time_error_s"] != "":
                        mod_time_err.setdefault(modification, []).append(row["time_error_s"])
                else:
                    mod_fn[modification] = mod_fn.get(modification, 0) + 1
            else:
                # Negative: the source is held out, so any hit at all is a false
                # positive (we don't require correct_ref here).
                if row["hit"]:
                    mod_fp[modification] = mod_fp.get(modification, 0) + 1
                else:
                    mod_tn[modification] = mod_tn.get(modification, 0) + 1

        # Report.
        # Modifications in stable order: none first, then requested distortions.
        # Include any mod that appears in any cell of the confusion matrix.
        ordered_mods = ["none"] + [m for m in distortions]
        ordered_mods = [m for m in ordered_mods
                        if (m in mod_tp or m in mod_fn or m in mod_fp or m in mod_tn)]

        def fmt(rate):
            return "  -  " if rate is None else "{:.3f}".format(rate)

        log.info("\n=== Olaf recognition benchmark ===")
        log.info("olaf commit:           %s", commit)
        log.info("config (fixed):        min_match_count=%s audio_step_size=%s "
                 "max_fingerprints=%s target_sample_rate=%s",
                 FIXED_CONFIG["min_match_count"], FIXED_CONFIG["audio_step_size"],
                 FIXED_CONFIG["max_fingerprints"], FIXED_CONFIG["target_sample_rate"])
        log.info("seed:                  %s", args.seed)
        log.info("segment length:        %.1f-%.1fs", args.min_seg, args.max_seg)
        log.info("files discovered:      %d", len(all_files))
        log.info("files usable:          %d", len(usable))
        log.info("files indexed (80%%):   %d (%d stored ok)", len(index_files), stored)
        log.info("files held out:        %d", len(holdout_files))
        log.info("time tolerance:        %.0f ms", TIME_TOLERANCE_S * 1000)
        for mod in ordered_mods:
            tp_m = mod_tp.get(mod, 0)
            fn_m = mod_fn.get(mod, 0)
            fp_m = mod_fp.get(mod, 0)
            tn_m = mod_tn.get(mod, 0)
            r = rates(tp_m, fn_m, fp_m, tn_m)
            mcs = mod_mc.get(mod, [])
            mean_m = sum(mcs) / len(mcs) if mcs else 0.0
            ok_m = mod_time_ok.get(mod, 0)
            time_acc = ok_m / tp_m if tp_m else 0.0
            errs = mod_time_err.get(mod, [])
            max_err = max(errs) if errs else 0.0
            log.info("%-14s TPR %s (TP=%d FN=%d)  TNR %s (FP=%d TN=%d)  P %s  F1 %s  "
                     "mc=%.1f | time %.0fms: %.3f (%d/%d, max err %.3fs)",
                     mod, fmt(r["tpr"]), tp_m, fn_m, fmt(r["tnr"]), fp_m, tn_m,
                     fmt(r["precision"]), fmt(r["f1"]), mean_m,
                     TIME_TOLERANCE_S * 1000, time_acc, ok_m, tp_m, max_err)

        # Overall headline summing every modification's confusion matrix.
        TP = sum(mod_tp.values())
        FN = sum(mod_fn.values())
        FP = sum(mod_fp.values())
        TN = sum(mod_tn.values())
        ov = rates(TP, FN, FP, TN)
        log.info("%-14s TPR %s (TP=%d FN=%d)  TNR %s (FP=%d TN=%d)  P %s  F1 %s  acc %s",
                 "OVERALL", fmt(ov["tpr"]), TP, FN, fmt(ov["tnr"]), FP, TN,
                 fmt(ov["precision"]), fmt(ov["f1"]), fmt(ov["accuracy"]))

        if args.csv:
            with open(args.csv, "w", newline="") as fh:
                fieldnames = list(rows[0].keys()) if rows else [
                    "segment", "source", "modification", "expected_match",
                    "hit", "correct_ref", "match_count", "ref_path",
                ]
                writer = csv.DictWriter(fh, fieldnames=fieldnames)
                writer.writeheader()
                writer.writerows(rows)
            log.info("per-segment results written to %s", args.csv)

    finally:
        if args.keep_workdir:
            log.info("Sandbox kept at %s", work_dir)
        else:
            shutil.rmtree(work_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
