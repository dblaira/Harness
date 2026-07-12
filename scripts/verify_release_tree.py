#!/usr/bin/env python3
"""Attest that a main-branch merge contains exactly the fully verified PR tree."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


REQUIRED_STATUS_CONTEXTS = {
    "Acceptance contract": "github-actions[bot]",
    "GPT-5.6 Sol review": "dblaira",
    "Signed Mac handoff": "dblaira",
}
REQUIRED_CHECK_CONTEXTS = {
    "Gate script tests",
    "macOS tests, SwiftLint, Periphery",
    "CodeQL (swift)",
    "CodeQL (python)",
}
REQUIRED_CONTEXTS = tuple(REQUIRED_STATUS_CONTEXTS) + tuple(sorted(REQUIRED_CHECK_CONTEXTS))


def latest_statuses(payload: dict) -> dict[str, dict]:
    latest: dict[str, dict] = {}
    statuses = payload if isinstance(payload, list) else payload.get("statuses", [])
    for status in statuses:
        context = status.get("context")
        if isinstance(context, str) and context not in latest:
            latest[context] = {
                "state": status.get("state"),
                "url": status.get("target_url"),
                "source": "commit-status",
                "creator": (status.get("creator") or {}).get("login"),
            }
    return latest


def latest_checks(payload: dict) -> dict[str, dict]:
    latest: dict[str, dict] = {}
    for check in payload.get("check_runs", []):
        name = check.get("name")
        if isinstance(name, str) and name not in latest:
            latest[name] = {
                "state": check.get("conclusion") if check.get("status") == "completed" else check.get("status"),
                "url": check.get("html_url"),
                "source": "check-run",
                "app": (check.get("app") or {}).get("slug"),
            }
    return latest


def validate(
    merge_sha: str,
    parent_line: str,
    merge_tree: str,
    verified_tree: str,
    statuses: dict,
    checks: dict,
) -> tuple[list[str], dict]:
    errors: list[str] = []
    parents = parent_line.split()
    if len(parents) != 3 or parents[0] != merge_sha:
        errors.append("main must receive a two-parent GitHub merge commit")
    verified_head = parents[2] if len(parents) >= 3 else ""
    if not merge_tree or merge_tree != verified_tree:
        errors.append("main merge tree does not exactly match the verified pull-request head tree")

    status_evidence = latest_statuses(statuses)
    check_evidence = latest_checks(checks)
    selected: dict[str, dict] = {}
    for context, creator in REQUIRED_STATUS_CONTEXTS.items():
        if context in check_evidence:
            errors.append(f"required status context is duplicated by a check run: {context}")
        result = status_evidence.get(context)
        if not result or result.get("state") != "success":
            errors.append(f"verified head lacks a latest successful required status: {context}")
        elif result.get("creator") != creator:
            errors.append(f"required status has an untrusted creator: {context}")
        else:
            selected[context] = result
    for context in REQUIRED_CHECK_CONTEXTS:
        if context in status_evidence:
            errors.append(f"required check context is duplicated by a commit status: {context}")
        result = check_evidence.get(context)
        if not result or result.get("state") != "success":
            errors.append(f"verified head lacks a latest successful required check: {context}")
        elif result.get("app") != "github-actions":
            errors.append(f"required check has an untrusted GitHub app: {context}")
        else:
            selected[context] = result

    attestation = {
        "schema_version": 1,
        "status": "PASS" if not errors else "FAIL",
        "main_commit": merge_sha,
        "verified_head": verified_head,
        "git_tree": merge_tree,
        "required_evidence": selected,
    }
    return errors, attestation


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--merge-sha", required=True)
    parser.add_argument("--parent-line", required=True)
    parser.add_argument("--merge-tree", required=True)
    parser.add_argument("--verified-tree", required=True)
    parser.add_argument("--statuses", type=Path, required=True)
    parser.add_argument("--checks", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    statuses = json.loads(args.statuses.read_text(encoding="utf-8"))
    checks = json.loads(args.checks.read_text(encoding="utf-8"))
    errors, attestation = validate(
        args.merge_sha,
        args.parent_line,
        args.merge_tree,
        args.verified_tree,
        statuses,
        checks,
    )
    args.output.write_text(json.dumps(attestation, indent=2) + "\n", encoding="utf-8")
    if errors:
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print(f"Release tree attested: {args.merge_sha} contains verified tree {args.merge_tree}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
