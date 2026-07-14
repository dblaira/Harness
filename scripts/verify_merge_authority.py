#!/usr/bin/env python3
"""Require trusted-user, commit-bound local statuses before merge."""

from __future__ import annotations

import argparse
import json
import sys


REQUIRED = {
    "Trusted hosted verification",
    "GPT-5.6 Sol review",
    "Signed Mac handoff",
}


def validate(payload: list[dict], marker: str) -> list[str]:
    latest: dict[str, dict] = {}
    for status in payload:
        context = status.get("context")
        if isinstance(context, str) and context not in latest:
            latest[context] = status
    errors: list[str] = []
    for context in REQUIRED:
        status = latest.get(context)
        if not status or status.get("state") != "success":
            errors.append(f"latest trusted merge status is not successful: {context}")
            continue
        if (status.get("creator") or {}).get("login") != "dblaira":
            errors.append(f"trusted merge status has the wrong creator: {context}")
        if marker not in str(status.get("description") or ""):
            errors.append(f"trusted merge status is bound to another PR or contract: {context}")
        if not str(status.get("target_url") or "").startswith("https://github.com/dblaira/Harness/"):
            errors.append(f"trusted merge status lacks repository evidence: {context}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--marker", required=True)
    args = parser.parse_args()
    try:
        payload = json.load(sys.stdin)
    except json.JSONDecodeError as error:
        print(f"invalid commit status JSON: {error}", file=sys.stderr)
        return 1
    if not isinstance(payload, list):
        print("commit status payload must be a list", file=sys.stderr)
        return 1
    errors = validate(payload, args.marker)
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1
    print("Trusted hosted, Sol, and signed handoff authorities permit merge.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
