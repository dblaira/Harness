#!/usr/bin/env python3
"""Reject links and remove nested instruction files from inert review snapshots."""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path


def sanitize(roots: list[Path]) -> list[str]:
    errors: list[str] = []
    for root in roots:
        root = root.resolve()
        if not root.is_dir():
            errors.append(f"review snapshot is missing: {root}")
            continue
        for directory, dirnames, filenames in os.walk(root, followlinks=False):
            parent = Path(directory)
            for name in dirnames + filenames:
                path = parent / name
                if path.is_symlink():
                    errors.append(f"review snapshot contains a forbidden symlink: {path.relative_to(root)}")
            for name in list(filenames):
                if name == "AGENTS.md":
                    (parent / name).unlink()
        leftovers = list(root.rglob("AGENTS.md"))
        if leftovers:
            errors.append(f"review snapshot contains a non-file AGENTS.md entry: {leftovers[0].relative_to(root)}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", nargs="+", type=Path)
    args = parser.parse_args()
    errors = sanitize(args.root)
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1
    print("Review snapshots contain no symlinks or nested AGENTS.md instructions.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
