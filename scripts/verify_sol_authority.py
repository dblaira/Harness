#!/usr/bin/env python3
"""Authenticate the newest Sol status and its local exact-commit review artifact."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import validate_sol_review


CONTEXT = "GPT-5.6 Sol review"
TRUSTED_CREATOR = "dblaira"


def verify(
    payload: dict,
    review: dict,
    expected_base: str,
    expected_head: str,
    marker: str,
    repository: str,
) -> tuple[list[str], str]:
    errors = validate_sol_review.validate(review, expected_base, expected_head)
    statuses = payload.get("statuses", [])
    latest = next(
        (
            item
            for item in statuses
            if isinstance(item, dict) and item.get("context") == CONTEXT
        ),
        None,
    )
    if latest is None:
        return [*errors, f"no {CONTEXT} status exists"], ""
    if latest.get("state") != "success":
        errors.append(f"newest {CONTEXT} status is not successful")
    if (latest.get("creator") or {}).get("login") != TRUSTED_CREATOR:
        errors.append(f"newest {CONTEXT} status was not created by {TRUSTED_CREATOR}")
    if marker not in str(latest.get("description", "")):
        errors.append(f"newest {CONTEXT} status is bound to a different acceptance contract")
    target_url = latest.get("target_url")
    expected_prefix = f"https://github.com/{repository}/"
    if not isinstance(target_url, str) or not target_url.startswith(expected_prefix):
        errors.append(f"newest {CONTEXT} status lacks a trusted repository evidence URL")
        target_url = ""
    return errors, target_url


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--review", required=True, type=Path)
    parser.add_argument("--expected-base", required=True)
    parser.add_argument("--expected-head", required=True)
    parser.add_argument("--description-contains", required=True)
    parser.add_argument("--repository", required=True)
    args = parser.parse_args()
    try:
        payload = json.load(sys.stdin)
        review = json.loads(args.review.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        print("invalid Sol authority evidence", file=sys.stderr)
        return 1
    errors, target_url = verify(
        payload,
        review,
        args.expected_base,
        args.expected_head,
        args.description_contains,
        args.repository,
    )
    if errors:
        print(f"Sol authority validation failed ({len(errors)} checks)", file=sys.stderr)
        return 1
    print(target_url)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
