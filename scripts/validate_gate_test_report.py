#!/usr/bin/env python3
"""Validate gate-test evidence in a fresh protected-base job."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def validate(report: dict) -> list[str]:
    errors: list[str] = []
    expected = report.get("expected_test_count")
    if report.get("status") != "PASS":
        errors.append("gate test report is not PASS")
    if not isinstance(expected, int) or expected < 1 or report.get("completed_test_count") != expected:
        errors.append("gate test report has incomplete inventory")
    if report.get("errors") != []:
        errors.append("gate test report contains errors")
    if not isinstance(report.get("transcript"), str) or "\nOK\n" not in f"\n{report.get('transcript', '')}\n":
        errors.append("gate test report lacks a complete transcript")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    try:
        report = json.loads(args.report.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"gate test report is invalid: {error}", file=sys.stderr)
        return 1
    errors = validate(report)
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1
    print("Fresh protected-base job validated the complete gate-test inventory.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
