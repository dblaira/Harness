#!/usr/bin/env python3
"""Bind installed local gate controls to the current protected PR base."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def validate(manifest: dict, control_dir: Path, repo_root: Path, base_sha: str) -> list[str]:
    errors: list[str] = []
    files = manifest.get("files")
    if not isinstance(files, dict) or not files:
        return ["installed control manifest has no files"]
    for relative, expected in sorted(files.items()):
        if not isinstance(relative, str) or not isinstance(expected, str):
            errors.append("installed control manifest has an invalid entry")
            continue
        local_path = control_dir / relative
        if not local_path.is_file() or digest(local_path.read_bytes()) != expected:
            errors.append(f"installed control differs from its manifest: {relative}")
            continue
        result = subprocess.run(
            ["/usr/bin/git", "show", f"{base_sha}:{relative}"],
            cwd=repo_root, capture_output=True, check=False,
        )
        if result.returncode or digest(result.stdout) != expected:
            errors.append(f"installed control is stale relative to protected base: {relative}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--control-dir", type=Path, required=True)
    parser.add_argument("--repo-root", type=Path, required=True)
    parser.add_argument("--base-sha", required=True)
    args = parser.parse_args()
    try:
        manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"installed control manifest is unreadable: {error}", file=sys.stderr)
        return 1
    errors = validate(manifest, args.control_dir, args.repo_root, args.base_sha)
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1
    print("Installed local controls match the current protected PR base.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
