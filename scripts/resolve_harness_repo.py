#!/usr/bin/env python3
"""Resolve the caller's Harness checkout without binding gates to one clone."""

from __future__ import annotations

import argparse
import re
import subprocess
from pathlib import Path


EXPECTED_REPOSITORY = "dblaira/Harness"


def run_git(cwd: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *args], cwd=cwd, text=True, capture_output=True, check=False
    )
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip() or "unknown git error"
        raise ValueError(f"git {' '.join(args)} failed: {detail}")
    return result.stdout.strip()


def repository_from_remote(remote: str) -> str | None:
    patterns = (
        r"^https://github\.com/(?P<repo>[^/]+/[^/]+?)(?:\.git)?$",
        r"^git@github\.com:(?P<repo>[^/]+/[^/]+?)(?:\.git)?$",
        r"^ssh://git@github\.com/(?P<repo>[^/]+/[^/]+?)(?:\.git)?$",
    )
    for pattern in patterns:
        match = re.fullmatch(pattern, remote.strip())
        if match:
            return match.group("repo")
    return None


def resolve(cwd: Path) -> Path:
    root = Path(run_git(cwd, "rev-parse", "--show-toplevel")).resolve()
    remote = run_git(root, "remote", "get-url", "origin")
    if repository_from_remote(remote) != EXPECTED_REPOSITORY:
        raise ValueError(
            f"release gates require origin {EXPECTED_REPOSITORY}; found {remote or 'no origin'}"
        )
    return root


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cwd", type=Path, default=Path.cwd())
    args = parser.parse_args()
    try:
        print(resolve(args.cwd))
    except ValueError as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
