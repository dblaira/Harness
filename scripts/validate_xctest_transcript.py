#!/usr/bin/env python3
"""Validate an exact protected Swift Testing inventory from direct xctest output."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
PASSED_TEST = re.compile(r"(?:✔|\[PASS\])\s+Test\s+([A-Za-z_][A-Za-z0-9_]*)\(\)\s+passed\b")
SUMMARY = re.compile(r"Test run with\s+(\d+)\s+tests?\s+in\s+\d+\s+suites?\s+passed\b")
FAILURE = re.compile(r"(?:✘|✗|\bfailed\b|\bfailures?\b|\bskipped\b|\bunexpected\b)", re.IGNORECASE)


def validate(expected_path: Path, transcript_path: Path) -> list[str]:
    errors: list[str] = []
    try:
        expected_payload = json.loads(expected_path.read_text(encoding="utf-8"))
        text = ANSI.sub("", transcript_path.read_text(encoding="utf-8", errors="replace"))
    except (OSError, json.JSONDecodeError) as error:
        return [f"cannot read direct xctest evidence: {error}"]
    if not isinstance(expected_payload, list) or not expected_payload or not all(
        isinstance(item, str) and item for item in expected_payload
    ):
        return ["protected xctest inventory must be a nonempty JSON string list"]
    expected = set(expected_payload)
    if len(expected) != len(expected_payload):
        errors.append("protected xctest inventory contains duplicate test names")
    observed_list = PASSED_TEST.findall(text)
    observed = set(observed_list)
    if len(observed) != len(observed_list):
        errors.append("direct xctest transcript contains duplicate passed test names")
    missing = sorted(expected - observed)
    extra = sorted(observed - expected)
    if missing:
        errors.append(f"direct xctest transcript is missing protected tests: {', '.join(missing)}")
    if extra:
        errors.append(f"direct xctest transcript contains unprotected tests: {', '.join(extra)}")
    summaries = [int(value) for value in SUMMARY.findall(text)]
    if summaries != [len(expected)]:
        errors.append(
            f"direct xctest transcript must contain one passing {len(expected)}-test summary"
        )
    failure_lines = []
    for line in text.splitlines():
        without_zero_counts = re.sub(
            r"\b0\s+(?:failures?|unexpected|skipped)\b", "", line, flags=re.IGNORECASE
        )
        if FAILURE.search(without_zero_counts):
            failure_lines.append(line.strip())
    if failure_lines:
        errors.append(f"direct xctest transcript contains failure language: {failure_lines[0]}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--expected", type=Path, required=True)
    parser.add_argument("--transcript", type=Path, required=True)
    args = parser.parse_args()
    errors = validate(args.expected, args.transcript)
    if errors:
        print("; ".join(errors), file=sys.stderr)
        return 1
    count = len(json.loads(args.expected.read_text(encoding="utf-8")))
    print(f"Direct isolated xctest evidence passed for {count} protected tests.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
