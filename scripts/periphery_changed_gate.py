#!/usr/bin/env python3
"""Run Periphery across the project but fail only for findings in changed Swift files."""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


def command(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, text=True, capture_output=True, check=False)


def scan_arguments(config: Path, output: Path, changed: set[str]) -> list[str]:
    include_args: list[str] = []
    for file_name in sorted(changed):
        include_args.extend(("--report-include", file_name))
    return [
        "periphery", "scan", "--config", str(config),
        "--project", "Harness.xcodeproj", "--schemes", "Harness",
        "--retain-public", "--retain-objc-annotated", "--format", "json", "--quiet",
        "--strict", "--write-results", str(output), *include_args,
    ]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--config", required=True, type=Path)
    args = parser.parse_args()
    root_result = command("git", "rev-parse", "--show-toplevel")
    if root_result.returncode:
        print(root_result.stderr, file=sys.stderr)
        return root_result.returncode
    root = Path(root_result.stdout.strip()).resolve()
    config = args.config.expanduser().resolve()
    if not config.is_file():
        print(f"Protected Periphery configuration is unavailable: {config}", file=sys.stderr)
        return 1
    base_result = command("git", "-C", str(root), "cat-file", "-e", f"{args.base}^{{commit}}")
    if base_result.returncode:
        print(f"Periphery base commit is unavailable: {args.base}", file=sys.stderr)
        return 1
    diff = command(
        "git", "-C", str(root), "diff", "--name-only", "--diff-filter=ACMR", f"{args.base}...HEAD", "--", "*.swift"
    )
    if diff.returncode:
        print(diff.stderr, file=sys.stderr)
        return diff.returncode
    changed = {str((root / item).resolve()) for item in diff.stdout.splitlines() if item}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if not changed:
        args.output.write_text("[]\n", encoding="utf-8")
        print("No changed Swift files; Periphery has no changed declarations to gate.")
        return 0
    scan = command(*scan_arguments(config, args.output, changed))
    if scan.returncode:
        print(scan.stderr or scan.stdout, file=sys.stderr)
        return scan.returncode
    if not args.output.exists():
        args.output.write_text(scan.stdout or "[]\n", encoding="utf-8")
    print(f"Periphery scanned the project; no findings in {len(changed)} changed Swift file(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
