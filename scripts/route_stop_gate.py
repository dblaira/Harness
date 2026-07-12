#!/usr/bin/env python3
"""Route the global Stop hook without allowing Harness resolution failures."""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

import resolve_harness_repo


HARNESS_MARKERS = (
    Path(".github/acceptance-contract.json"),
    Path("project.yml"),
    Path("Sources/Harness"),
)


def git_root(cwd: Path) -> Path | None:
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"], cwd=cwd,
        text=True, capture_output=True, check=False,
    )
    if result.returncode:
        return None
    return Path(result.stdout.strip()).resolve()


def is_within(path: Path, parent: Path) -> bool:
    try:
        path.resolve().relative_to(parent.resolve())
        return True
    except ValueError:
        return False


def route(cwd: Path, installed_root: Path) -> Path | None:
    cwd = cwd.resolve()
    root = git_root(cwd)
    if root is None:
        if is_within(cwd, installed_root):
            raise ValueError("Harness Git metadata is unreadable; Stop gate stays closed")
        return None
    try:
        return resolve_harness_repo.resolve(root)
    except ValueError as error:
        if root == installed_root.resolve() or all((root / marker).exists() for marker in HARNESS_MARKERS):
            raise ValueError(f"Harness repository resolution failed; Stop gate stays closed: {error}") from error
        return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cwd", type=Path, required=True)
    parser.add_argument("--installed-root", type=Path, required=True)
    args = parser.parse_args()
    try:
        root = route(args.cwd, args.installed_root)
    except ValueError as error:
        print(error, file=sys.stderr)
        return 20
    if root is None:
        return 10
    print(root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
