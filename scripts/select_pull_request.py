#!/usr/bin/env python3
"""Select exactly one open main-targeting pull request for a head SHA."""

from __future__ import annotations

import argparse
import json
import sys
from typing import Any


def select_pull_request(pulls: Any, head_sha: str) -> dict[str, Any]:
    if not isinstance(pulls, list):
        raise ValueError("pull request response must be a list")
    open_pulls = [pull for pull in pulls if isinstance(pull, dict) and pull.get("state") == "open"]
    matching = [
        pull for pull in open_pulls
        if (pull.get("base") or {}).get("ref") == "main"
        and (pull.get("head") or {}).get("sha") == head_sha
    ]
    if len(open_pulls) != 1 or len(matching) != 1:
        raise ValueError(f"commit {head_sha} must belong to exactly one open pull request targeting main")
    if not str((matching[0].get("head") or {}).get("ref") or "").startswith("codex/"):
        raise ValueError("release pull request must use an agent-owned codex/ branch")
    return matching[0]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--head-sha", required=True)
    args = parser.parse_args()
    try:
        pulls = json.load(sys.stdin)
        print(json.dumps(select_pull_request(pulls, args.head_sha), separators=(",", ":")))
    except (ValueError, json.JSONDecodeError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
