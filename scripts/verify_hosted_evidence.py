#!/usr/bin/env python3
"""Verify hosted checks by immutable workflow identity before local aggregation."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path


STATUS_WORKFLOWS = {
    "Acceptance contract": ".github/workflows/acceptance-contract.yml",
    "Gate script tests": ".github/workflows/verification.yml",
    "macOS tests, SwiftLint, Periphery": ".github/workflows/verification.yml",
}
CHECK_WORKFLOW = ".github/workflows/codeql.yml"
CHECK_NAMES = {"CodeQL (swift)", "CodeQL (python)"}
PROTECTED_CONTROL_PATHS = (
    "AGENTS.md",
    "project.yml",
    "Sources/Harness/Harness.entitlements",
    "Packages/OntologyKit/Package.swift",
    ".periphery.yml",
    ".swiftlint.yml",
    ".github/workflows",
    ".github/codex",
    ".codex/hooks.json",
    ".cursor/rules/verified-gates.mdc",
    "script",
    "scripts/evidence_binding.py",
    "scripts/periphery_changed_gate.py",
    "scripts/preflight_tcc.swift",
    "scripts/lint_changed_swift.sh",
    "scripts/live_satisfaction_oracle.py",
    "scripts/prepare_protected_tests.py",
    "scripts/readonly_ollama_proxy.py",
    "scripts/readonly_sparql_proxy.py",
    "scripts/release_gate.py",
    "scripts/configure_isolated_xcode_home.swift",
    "scripts/render_sol_review.py",
    "scripts/require_latest_status.py",
    "scripts/resolve_harness_repo.py",
    "scripts/route_stop_gate.py",
    "scripts/run_gate_script_tests.py",
    "scripts/run_accessibility_contract.swift",
    "scripts/run_with_timeout.py",
    "scripts/snapshot_authority_bindings.py",
    "scripts/snapshot_authority_state.py",
    "scripts/snapshot_gate_dependencies.py",
    "scripts/snapshot_ollama_state.py",
    "scripts/sync-ontology.sh",
    "scripts/sanitize_review_bundle.py",
    "scripts/select_pull_request.py",
    "scripts/swift_test_inventory.py",
    "scripts/tests",
    "scripts/validate_acceptance_contract.py",
    "scripts/validate_gate_test_report.py",
    "scripts/validate_media.py",
    "scripts/validate_periphery_report.py",
    "scripts/validate_sol_review.py",
    "scripts/validate_xctest_transcript.py",
    "scripts/validate_xcresult.py",
    "scripts/validate_swiftpm_tests.py",
    "scripts/verify_app_identity.py",
    "scripts/verify_codex_auth.py",
    "scripts/verify_codex_runtime.py",
    "scripts/verify_control_bundle.py",
    "scripts/verify_hosted_evidence.py",
    "scripts/verify_merge_authority.py",
    "scripts/verify_repository_gate_state.py",
    "scripts/verify_release_tree.py",
    "scripts/verify_release_tree_run.py",
    "scripts/verify_running_app.swift",
    "scripts/verify_sol_authority.py",
    "Tests/HarnessUITests/HarnessCriticalFlowTests.swift",
    "Tests/HarnessUITests/HarnessHostedSmokeTests.swift",
    "Tests/HarnessUITests/HarnessRequirementEvidence.swift",
    "Packages/OntologyKit/Tests/OntologyKitTests/SatisfactionGateLiveTests.swift",
)
RUN_ID = re.compile(r"/actions/runs/(\d+)(?:/|$)")
JOB_ID = re.compile(r"/(?:actions/runs/\d+/job|runs)/(\d+)(?:/|$)")
BOOTSTRAP_AUTHORITY = ("dblaira/Harness", 19, "0ce97219a340d9a53f5afb2a773bb2c9eb81b807")


def gh_json(path: str) -> dict | list:
    result = subprocess.run(["gh", "api", path], text=True, capture_output=True, check=False)
    if result.returncode:
        raise ValueError(result.stderr.strip() or f"GitHub API failed: {path}")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise ValueError(f"GitHub API returned invalid JSON for {path}: {error}") from error


def latest_statuses(payload: list[dict]) -> dict[str, dict]:
    latest: dict[str, dict] = {}
    for status in payload:
        context = status.get("context")
        if isinstance(context, str) and context not in latest:
            latest[context] = status
    return latest


def latest_checks(payload: dict) -> dict[str, dict]:
    latest: dict[str, dict] = {}
    for check in payload.get("check_runs", []):
        name = check.get("name")
        if isinstance(name, str) and name not in latest:
            latest[name] = check
    return latest


def validate_status(
    context: str,
    status: dict | None,
    run: dict | None,
    repository: str,
    base_sha: str,
    head_sha: str,
    pr_number: int | None,
) -> list[str]:
    errors: list[str] = []
    if not status or status.get("state") != "success":
        return [f"hosted status is not successful: {context}"]
    if (status.get("creator") or {}).get("login") != "github-actions[bot]":
        errors.append(f"hosted status has the wrong creator: {context}")
    if not run:
        errors.append(f"hosted status lacks a resolvable workflow run: {context}")
        return errors
    bootstrap = (repository, pr_number, base_sha) == BOOTSTRAP_AUTHORITY
    expected_event = "pull_request" if bootstrap else "pull_request_target"
    expected_run_head = head_sha if bootstrap else base_sha
    if run.get("path") != STATUS_WORKFLOWS[context] or run.get("event") != expected_event:
        errors.append(f"hosted status came from the wrong protected workflow: {context}")
    if run.get("head_sha") != expected_run_head or run.get("conclusion") != "success":
        errors.append(f"protected workflow run is stale or unsuccessful: {context}")
    if (run.get("repository") or {}).get("full_name") != repository:
        errors.append(f"protected workflow run belongs to another repository: {context}")
    pull_requests = run.get("pull_requests") or []
    exact_pull = any(
        pull.get("number") == pr_number
        and (pull.get("base") or {}).get("sha") == base_sha
        and (pull.get("head") or {}).get("sha") == head_sha
        for pull in pull_requests
        if isinstance(pull, dict)
    )
    if not exact_pull:
        errors.append(f"protected workflow run is not bound to the exact pull request: {context}")
    return errors


def validate_check(
    name: str,
    check: dict | None,
    job: dict | None,
    run: dict | None,
    repository: str,
    head_sha: str,
) -> list[str]:
    errors: list[str] = []
    if not check or check.get("status") != "completed" or check.get("conclusion") != "success":
        return [f"CodeQL check is not successful: {name}"]
    if (check.get("app") or {}).get("slug") != "github-actions":
        errors.append(f"CodeQL check has the wrong app: {name}")
    if not job or not run or job.get("run_id") != run.get("id"):
        errors.append(f"CodeQL check lacks a resolvable job and run: {name}")
        return errors
    if job.get("head_sha") != head_sha or job.get("conclusion") != "success":
        errors.append(f"CodeQL job is stale or unsuccessful: {name}")
    if run.get("path") != CHECK_WORKFLOW or run.get("event") != "pull_request":
        errors.append(f"CodeQL check came from the wrong workflow: {name}")
    if run.get("head_sha") != head_sha or run.get("conclusion") != "success":
        errors.append(f"CodeQL workflow run is stale or unsuccessful: {name}")
    if (run.get("repository") or {}).get("full_name") != repository:
        errors.append(f"CodeQL workflow run belongs to another repository: {name}")
    return errors


def unchanged_protected_controls(
    repo_root: Path,
    base_sha: str,
    head_sha: str,
    repository: str | None = None,
    pr_number: int | None = None,
) -> list[str]:
    result = subprocess.run(
        ["/usr/bin/git", "diff", "--quiet", base_sha, head_sha, "--", *PROTECTED_CONTROL_PATHS],
        cwd=repo_root, check=False,
    )
    if result.returncode == 0 or (repository, pr_number, base_sha) == BOOTSTRAP_AUTHORITY:
        return []
    return [
        "protected hosted workflow files changed; use the separately reviewed infrastructure bootstrap path"
    ]


def collect_and_validate(
    repository: str,
    repo_root: Path,
    base_sha: str,
    head_sha: str,
    pr_number: int | None = None,
) -> tuple[list[str], dict]:
    status_payload = gh_json(f"repos/{repository}/commits/{head_sha}/statuses?per_page=100")
    check_payload = gh_json(f"repos/{repository}/commits/{head_sha}/check-runs?filter=latest&per_page=100")
    if not isinstance(status_payload, list) or not isinstance(check_payload, dict):
        raise ValueError("hosted evidence APIs returned unexpected payloads")
    statuses = latest_statuses(status_payload)
    checks = latest_checks(check_payload)
    errors = unchanged_protected_controls(repo_root, base_sha, head_sha, repository, pr_number)
    evidence: dict[str, dict] = {}
    for context in STATUS_WORKFLOWS:
        status = statuses.get(context)
        target = str((status or {}).get("target_url") or "")
        match = RUN_ID.search(target)
        run = gh_json(f"repos/{repository}/actions/runs/{match.group(1)}") if match else None
        if run is not None and not isinstance(run, dict):
            run = None
        errors.extend(
            validate_status(
                context, status, run, repository, base_sha, head_sha, pr_number
            )
        )
        if status and run:
            evidence[context] = {"status_url": target, "run_id": run.get("id"), "workflow": run.get("path")}
    for name in CHECK_NAMES:
        check = checks.get(name)
        details = str((check or {}).get("details_url") or "")
        match = JOB_ID.search(details)
        job = gh_json(f"repos/{repository}/actions/jobs/{match.group(1)}") if match else None
        run = gh_json(f"repos/{repository}/actions/runs/{job.get('run_id')}") if isinstance(job, dict) else None
        if job is not None and not isinstance(job, dict):
            job = None
        if run is not None and not isinstance(run, dict):
            run = None
        errors.extend(validate_check(name, check, job, run, repository, head_sha))
        if check and job and run:
            evidence[name] = {"details_url": details, "run_id": run.get("id"), "workflow": run.get("path")}
    return errors, evidence


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--repo-root", type=Path, required=True)
    parser.add_argument("--base-sha", required=True)
    parser.add_argument("--head-sha", required=True)
    parser.add_argument("--pr-number", type=int)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        errors, evidence = collect_and_validate(
            args.repo, args.repo_root, args.base_sha, args.head_sha, args.pr_number
        )
    except ValueError as error:
        errors, evidence = [str(error)], {}
    report = {"status": "PASS" if not errors else "FAIL", "head_sha": args.head_sha, "evidence": evidence, "errors": errors}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1
    print("Hosted acceptance, gate tests, macOS verification, and CodeQL runs are trusted and exact-head-bound.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
