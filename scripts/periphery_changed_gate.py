#!/usr/bin/env python3
"""Run Periphery across the project but fail only for findings on changed Swift lines."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path


def command(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, text=True, capture_output=True, check=False)


HUNK_PATTERN = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")


def scan_arguments(config: Path, output: Path) -> list[str]:
    return [
        "periphery", "scan", "--config", str(config),
        "--project", "Harness.xcodeproj", "--schemes", "Harness",
        "--retain-public", "--retain-objc-annotated", "--format", "json", "--quiet",
        "--write-results", str(output),
    ]


def parse_changed_lines(diff: str, root: Path) -> dict[Path, set[int]]:
    changed: dict[Path, set[int]] = {}
    current: Path | None = None
    for line in diff.splitlines():
        if line == "+++ /dev/null":
            current = None
            continue
        if line.startswith("+++ b/"):
            current = (root / line[6:]).resolve()
            changed.setdefault(current, set())
            continue
        if current is None:
            continue
        match = HUNK_PATTERN.match(line)
        if not match:
            continue
        start = int(match.group(1))
        count = int(match.group(2) or "1")
        changed[current].update(range(start, start + count))
    return changed


def changed_findings(findings: list[dict], changed: dict[Path, set[int]]) -> list[dict]:
    relevant: list[dict] = []
    for finding in findings:
        location = str(finding.get("location") or "")
        try:
            path_text, line_text, _ = location.rsplit(":", 2)
            path = Path(path_text).resolve()
            line = int(line_text)
        except (TypeError, ValueError):
            continue
        if line in changed.get(path, set()):
            relevant.append(finding)
    return relevant


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
        "git", "-C", str(root), "diff", "--unified=0", "--no-color", "--no-ext-diff",
        args.base, "HEAD", "--", "*.swift",
    )
    if diff.returncode:
        print(diff.stderr, file=sys.stderr)
        return diff.returncode
    changed = parse_changed_lines(diff.stdout, root)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if not any(changed.values()):
        args.output.write_text("[]\n", encoding="utf-8")
        print("No added or changed Swift lines; Periphery has nothing to gate.")
        return 0
    with tempfile.TemporaryDirectory(prefix="harness-periphery-") as directory:
        raw_output = Path(directory) / "all-findings.json"
        scan = command(*scan_arguments(config, raw_output))
        if scan.returncode or not raw_output.is_file():
            print(scan.stderr or scan.stdout or "Periphery did not produce JSON evidence.", file=sys.stderr)
            return scan.returncode or 1
        try:
            findings = json.loads(raw_output.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            print(f"Periphery evidence is invalid: {error}", file=sys.stderr)
            return 1
    if not isinstance(findings, list):
        print("Periphery evidence must be a JSON list.", file=sys.stderr)
        return 1
    relevant = changed_findings(findings, changed)
    args.output.write_text(json.dumps(relevant, indent=2) + "\n", encoding="utf-8")
    if relevant:
        print(f"Periphery found {len(relevant)} issue(s) on added or changed Swift lines.", file=sys.stderr)
        return 1
    print(f"Periphery scanned the project; no findings on changed lines in {len(changed)} Swift file(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
