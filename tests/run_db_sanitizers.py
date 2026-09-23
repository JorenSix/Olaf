#!/usr/bin/env python3
"""Instrument production C sources and run the focused DB tests (Clang required)."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def run(argv, **kwargs):
    return subprocess.run(argv, check=True, timeout=60, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sanitizer", choices=("address", "thread"), default="address")
    args = parser.parse_args()
    sanitizers = "address,undefined" if args.sanitizer == "address" else "thread"
    flags = [os.environ.get("CC", "clang"), "-std=gnu11", "-g", "-O1", "-UNDEBUG",
             "-fno-omit-frame-pointer", "-fno-sanitize-recover=all",
             f"-fsanitize={sanitizers}", "-pthread", "-Isrc"]
    with tempfile.TemporaryDirectory(prefix="olaf-db-sanitizers-") as folder:
        tmp = Path(folder)
        writer, helper = tmp / "writer", tmp / "db"
        run(flags + ["tests/olaf_fp_db_writer_tests.c", "src/olaf_fp_db_writer.c", "-o", str(writer)], cwd=ROOT)
        run(flags + ["-DOLAF_DB_TESTING", "tests/olaf_db_concurrency_tests.c", "src/olaf_db.c",
                     "src/mdb.c", "src/midl.c", "-o", str(helper)], cwd=ROOT)
        run([str(writer)])
        a, b, separate, missing = [tmp / name for name in ("a", "b", "separate", "missing")]
        for path in (a, b, separate, missing):
            path.mkdir()
        alias = tmp / "alias"
        alias.symlink_to(a, target_is_directory=True)
        run([str(helper), "all", str(a), str(b), "alias/"], cwd=tmp)
        result = subprocess.run([str(helper), "missing", str(missing)], timeout=60, capture_output=True)
        assert result.returncode == 214, result.stderr.decode(errors="replace")
        assert not (missing / "data.mdb").exists()
        run([str(helper), "seed", str(separate)])
        child = subprocess.Popen([str(helper), "reader", str(separate)], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        try:
            assert child.stdout.read(1) == b"R"  # helper watchdog bounds this wait
            run([str(helper), "replace", str(separate)])
            child.communicate(b"C", timeout=60)
            assert child.returncode == 0, child.returncode
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()
            child.stdin.close()
            child.stdout.close()
    print(f"DB safety tests passed with {sanitizers}")


if __name__ == "__main__":
    main()
