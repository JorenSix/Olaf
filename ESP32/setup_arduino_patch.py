#!/usr/bin/env python3

# small helper script to link to source files in a way expected
# by the arduino IDE

import os
import sys

SOURCE_FILES = [
    "hash-table.c",
    "olaf_config.c",
    "olaf_db_mem.c",
    "olaf_ep_extractor.c",
    "olaf_fp_extractor.c",
    "olaf_fp_matcher.c",
    "olaf_max_filter_perceptual_van_herk.c",
    "pffft.c",
]

HEADER_FILES = [
    "hash-table.h",
    "olaf_config.h",
    "olaf_db.h",
    "olaf_ep_extractor.h",
    "olaf_fp_extractor.h",
    "olaf_fp_matcher.h",
    "olaf_fp_ref_mem.h",
    "olaf_max_filter.h",
    "olaf_window.h",
    "pffft.h",
]


def link(target, link_path):
    if os.path.islink(link_path) or os.path.exists(link_path):
        # idempotent: a re-run should not fail on links it already made
        return
    try:
        os.symlink(target, link_path)
    except OSError as err:
        print("Error: could not link %s -> %s: %s" % (link_path, target, err), file=sys.stderr)
        sys.exit(1)


def main():
    if len(sys.argv) != 2:
        print("A single folder name is expected as argument", file=sys.stderr)
        sys.exit(1)

    folder = sys.argv[1]

    if not os.path.exists(folder):
        os.makedirs(folder)
        open(os.path.join(folder, "%s.ino" % folder), "a").close()

    for header_file in HEADER_FILES:
        link(os.path.join("../../src", header_file), os.path.join(folder, header_file))

    for source_file in SOURCE_FILES:
        link(
            os.path.join("../../src", source_file),
            os.path.join(folder, "%spp" % source_file),
        )


if __name__ == "__main__":
    main()
