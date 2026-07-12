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


def remote_ref_sha(root: Path, ref: str) -> str:
    result = subprocess.run(
        ["git", "ls-remote", "--exit-code", "origin", ref],
        cwd=root,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip() or "remote ref unavailable"
        raise ValueError(f"cannot read protected remote ref {ref}: {detail}")
    lines = [line.split() for line in result.stdout.splitlines() if line.strip()]
    if len(lines) != 1 or len(lines[0]) < 2 or lines[0][1] != ref:
        raise ValueError(f"remote ref {ref} did not resolve uniquely")
    return lines[0][0]


def require_remote_ref(root: Path, ref: str) -> None:
    local = run_git(root, "rev-parse", "HEAD")
    remote = remote_ref_sha(root, ref)
    if local != remote:
        raise ValueError(f"local HEAD {local} does not equal protected origin {ref} at {remote}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cwd", type=Path, default=Path.cwd())
    parser.add_argument("--require-ref")
    args = parser.parse_args()
    try:
        root = resolve(args.cwd)
        if args.require_ref:
            require_remote_ref(root, args.require_ref)
        print(root)
    except ValueError as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
