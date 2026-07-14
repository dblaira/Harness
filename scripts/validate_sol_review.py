#!/usr/bin/env python3
"""Validate the structured independent GPT-5.6 Sol review result."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def validate(review: dict, expected_base: str, expected_head: str) -> list[str]:
    errors: list[str] = []
    if review.get("reviewed_base") != expected_base:
        errors.append("reviewed_base does not match the pull request base SHA")
    if review.get("reviewed_head") != expected_head:
        errors.append("reviewed_head does not match the pull request head SHA")
    if review.get("verdict") != "PASS":
        errors.append("Sol verdict is not PASS")
    if review.get("acceptance_contract_complete") is not True:
        errors.append("Sol did not confirm the acceptance contract")
    if review.get("read_only_review") is not True:
        errors.append("Sol did not attest that the review was read-only")
    findings = review.get("findings")
    if not isinstance(findings, list):
        errors.append("findings must be a list")
    else:
        blocking = [item for item in findings if item.get("severity") in {"P0", "P1"}]
        if blocking:
            errors.append(f"Sol found {len(blocking)} blocking P0/P1 finding(s)")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--review", required=True, type=Path)
    parser.add_argument("--expected-base", required=True)
    parser.add_argument("--expected-head", required=True)
    args = parser.parse_args()
    try:
        review = json.loads(args.review.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"Invalid Sol review output: {error}", file=sys.stderr)
        return 1
    errors = validate(review, args.expected_base, args.expected_head)
    if errors:
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print("Independent GPT-5.6 Sol review passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
