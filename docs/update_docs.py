#!/usr/bin/env python3

# small script to update the gh-pages branch with the newest doxygen docs

import os
import shutil
import subprocess
import sys
import tempfile

HTML_FILES = "docs/api/html/"
REPO = "git@github.com:JorenSix/Olaf.git"


def run(cmd, cwd=None):
    result = subprocess.run(cmd, cwd=cwd)
    if result.returncode != 0:
        print("Error: command failed (exit %d): %s" % (result.returncode, " ".join(cmd)), file=sys.stderr)
        sys.exit(result.returncode)


def main():
    # Call doxygen to generate the new html docs
    if shutil.which("doxygen") is None:
        print("Error: doxygen not found", file=sys.stderr)
        print("Please install it with for example\nbrew install doxygen", file=sys.stderr)
        sys.exit(1)

    run(["doxygen"])

    if not os.path.isdir(HTML_FILES) or not os.listdir(HTML_FILES):
        print("Error: no generated docs found in '%s'" % HTML_FILES, file=sys.stderr)
        sys.exit(1)

    # In a temp dir do the following
    with tempfile.TemporaryDirectory() as d:
        clone = os.path.join(d, "Olaf")

        # Clone the olaf repo in a temporary dir
        run(["git", "clone", REPO], cwd=d)

        # Checkout the gh-pages branch
        run(["git", "checkout", "gh-pages"], cwd=clone)

        # Copy the new docs to the directory
        for entry in os.listdir(HTML_FILES):
            src = os.path.join(HTML_FILES, entry)
            dst = os.path.join(clone, entry)
            if os.path.isdir(src):
                shutil.copytree(src, dst, dirs_exist_ok=True)
            else:
                shutil.copy2(src, dst)

        # Add and commit; a clean tree (nothing changed) is not an error
        run(["git", "add", "."], cwd=clone)
        commit = subprocess.run(["git", "commit", "-m", "docs"], cwd=clone)
        if commit.returncode != 0:
            print("Nothing to commit: docs are already up to date.")
            return

        # Push to the branch
        run(["git", "push", "origin", "gh-pages"], cwd=clone)


if __name__ == "__main__":
    main()
