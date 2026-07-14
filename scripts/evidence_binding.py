#!/usr/bin/env python3
"""Create one digest that binds local evidence to one exact pull request contract."""

from __future__ import annotations

import argparse
import hashlib
import json


def binding_digest(
    repository: str,
    pr_number: int,
    base_sha: str,
    head_sha: str,
    contract_digest: str,
) -> str:
    payload = {
        "repository": repository,
        "pr_number": pr_number,
        "base_sha": base_sha,
        "head_sha": head_sha,
        "contract_digest": contract_digest,
    }
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--pr-number", required=True, type=int)
    parser.add_argument("--base-sha", required=True)
    parser.add_argument("--head-sha", required=True)
    parser.add_argument("--contract-digest", required=True)
    args = parser.parse_args()
    print(binding_digest(
        args.repo,
        args.pr_number,
        args.base_sha,
        args.head_sha,
        args.contract_digest,
    ))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
