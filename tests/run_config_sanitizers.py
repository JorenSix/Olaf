#!/usr/bin/env python3
"""Run config/constructor regressions with ASan + UBSan, SIMD and scalar."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
SOURCES = [
    "hash-table", "pffft", "queue", "olaf_deque",
    "olaf_max_filter_perceptual_van_herk", "olaf_config", "olaf_db_id",
    "olaf_ep_extractor", "olaf_fp_db_writer_cache", "olaf_fp_file_writer",
    "olaf_fp_extractor", "olaf_fp_matcher", "olaf_reader_stream",
    "olaf_runner", "olaf_stream_processor", "olaf_db_mem",
    "olaf_fp_db_writer_mem", "olaf_fft",
]


def run(argv):
    subprocess.run(argv, cwd=ROOT, check=True, timeout=120)


def main():
    flags = [os.environ.get("CC", "clang"), "-std=gnu11", "-O1", "-g",
             "-DNDEBUG", "-Isrc", "-fno-omit-frame-pointer",
             "-fno-sanitize-recover=all", "-fsanitize=address,undefined"]
    with tempfile.TemporaryDirectory(prefix="olaf-config-sanitizers-") as folder:
        tmp = Path(folder)
        for scalar in (False, True):
            variant = flags + (["-DPFFFT_SIMD_DISABLE", "-U__ARM_NEON"] if scalar else [])
            objects = []
            for name in SOURCES:
                obj = tmp / f"{name}.o"
                run(variant + ["-include", "tests/olaf_config_alloc.h", "-c", f"src/{name}.c", "-o", str(obj)])
                objects.append(str(obj))
            exe = tmp / "config-tests"
            run(variant + ["tests/olaf_config_tests.c", *objects, "-lm", "-o", str(exe)])
            run([str(exe), str(ROOT / "tests/golden/output_snapshot.txt")])
    print("Configuration safety tests passed with ASan/UBSan (SIMD and scalar)")


if __name__ == "__main__":
    main()
