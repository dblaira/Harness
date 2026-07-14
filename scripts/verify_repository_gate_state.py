#!/usr/bin/env python3
"""Fail closed unless GitHub still matches the installed Harness gate policy."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys


REQUIRED_CONTEXTS = {
    "Trusted hosted verification",
    "GPT-5.6 Sol review",
    "Signed Mac handoff",
}


def validate(
    repository: dict,
    protection: dict,
    actions: dict,
    workflow_permissions: dict,
    selected_actions: dict,
    runners: dict,
) -> list[str]:
    errors: list[str] = []
    status_checks = protection.get("required_status_checks") or {}
    if set(status_checks.get("contexts") or []) != REQUIRED_CONTEXTS:
        errors.append("required status contexts differ from trusted local issuers")
    if status_checks.get("strict") is not True:
        errors.append("strict up-to-date status checks are disabled")
    if not (protection.get("enforce_admins") or {}).get("enabled"):
        errors.append("branch protection does not enforce administrators")
    if not protection.get("required_pull_request_reviews"):
        errors.append("pull requests are not required")
    if not (protection.get("required_conversation_resolution") or {}).get("enabled"):
        errors.append("conversation resolution is not required")
    if (protection.get("allow_force_pushes") or {}).get("enabled"):
        errors.append("force pushes are allowed")
    if (protection.get("allow_deletions") or {}).get("enabled"):
        errors.append("protected main can be deleted")
    if (protection.get("required_linear_history") or {}).get("enabled"):
        errors.append("linear history conflicts with required merge commits")
    if not repository.get("allow_merge_commit") or repository.get("allow_squash_merge") or repository.get("allow_rebase_merge"):
        errors.append("repository is not merge-commit-only")
    if actions.get("enabled") is not True or actions.get("allowed_actions") != "selected":
        errors.append("Actions are not restricted to the selected policy")
    if actions.get("sha_pinning_required") is not True:
        errors.append("Actions SHA pinning is not required")
    if workflow_permissions.get("default_workflow_permissions") != "read":
        errors.append("default workflow token permissions are not read-only")
    if workflow_permissions.get("can_approve_pull_request_reviews") is not False:
        errors.append("workflows can approve pull requests")
    if selected_actions.get("github_owned_allowed") is not True:
        errors.append("GitHub-owned actions are not allowed")
    if selected_actions.get("verified_allowed") is not False:
        errors.append("third-party verified actions are unexpectedly allowed")
    if selected_actions.get("patterns_allowed") not in ([], None):
        errors.append("additional Actions patterns are allowed")
    if runners.get("total_count") != 0:
        errors.append("public repository has a self-hosted runner")
    return errors


def gh_json(path: str) -> dict:
    result = subprocess.run(["gh", "api", path], text=True, capture_output=True, check=False)
    if result.returncode:
        raise ValueError(result.stderr.strip() or f"GitHub API failed: {path}")
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise ValueError(f"GitHub API returned invalid JSON for {path}: {error}") from error
    if not isinstance(payload, dict):
        raise ValueError(f"GitHub API returned a non-object for {path}")
    return payload


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    args = parser.parse_args()
    repo = args.repo
    try:
        errors = validate(
            gh_json(f"repos/{repo}"),
            gh_json(f"repos/{repo}/branches/main/protection"),
            gh_json(f"repos/{repo}/actions/permissions"),
            gh_json(f"repos/{repo}/actions/permissions/workflow"),
            gh_json(f"repos/{repo}/actions/permissions/selected-actions"),
            gh_json(f"repos/{repo}/actions/runners"),
        )
    except ValueError as error:
        print(error, file=sys.stderr)
        return 1
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1
    print("Protected main, Actions policy, merge modes, and runner state match the trusted gate policy.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
