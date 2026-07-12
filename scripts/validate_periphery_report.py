#!/usr/bin/env python3
"""Require a parseable, empty changed-line Periphery evidence list."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    try:
        report = json.loads(args.report.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"Periphery report is invalid: {error}", file=sys.stderr)
        return 1
    if not isinstance(report, list) or report:
        print("Periphery changed-line report is not an empty JSON list", file=sys.stderr)
        return 1
    print("Fresh protected-base job validated empty changed-line Periphery evidence.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
