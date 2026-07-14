#!/usr/bin/env python3
"""Hash exact operator tools and verifier entry points used by a handoff."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path


def digest_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def snapshot(paths: list[Path]) -> tuple[list[str], dict]:
    errors: list[str] = []
    entries: list[dict] = []
    for path in paths:
        absolute = path.absolute()
        if not absolute.exists() and not absolute.is_symlink():
            errors.append(f"protected dependency is missing: {absolute}")
            continue
        entry: dict[str, object] = {"path": str(absolute)}
        if absolute.is_symlink():
            entry["symlink"] = os.readlink(absolute)
        resolved = absolute.resolve()
        if not resolved.is_file():
            errors.append(f"protected dependency is not a file: {absolute}")
            continue
        entry["resolved_path"] = str(resolved)
        entry["sha256"] = digest_file(resolved)
        entries.append(entry)
    entries.sort(key=lambda item: str(item["path"]))
    canonical = json.dumps(entries, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return errors, {
        "schema_version": 1,
        "sha256": hashlib.sha256(canonical).hexdigest(),
        "files": entries,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--path", action="append", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    errors, result = snapshot(args.path)
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
