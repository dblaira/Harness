#!/usr/bin/env python3
"""Require the newest GitHub commit status for one context to be successful."""

from __future__ import annotations

import argparse
import json
import sys


def require_latest(payload: dict, context: str) -> tuple[list[str], str]:
    statuses = payload.get("statuses", [])
    latest = next(
        (item for item in statuses if isinstance(item, dict) and item.get("context") == context),
        None,
    )
    if latest is None:
        return [f"no {context} status exists"], ""
    if latest.get("state") != "success":
        return [f"newest {context} status is {latest.get('state') or 'invalid'}"], ""
    target_url = latest.get("target_url")
    if not isinstance(target_url, str) or not target_url.strip():
        return [f"newest {context} status lacks an evidence URL"], ""
    return [], target_url


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--context", required=True)
    args = parser.parse_args()
    try:
        payload = json.load(sys.stdin)
    except json.JSONDecodeError as error:
        print(f"invalid combined-status JSON: {error}", file=sys.stderr)
        return 1
    errors, target_url = require_latest(payload, args.context)
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1
    print(target_url)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
