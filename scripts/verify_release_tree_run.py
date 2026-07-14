#!/usr/bin/env python3
"""Wait for and independently verify the exact merged-tree workflow artifact."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
import time
import zipfile
from io import BytesIO
from pathlib import Path


WORKFLOW_PATH = ".github/workflows/release-tree-attestation.yml"
STATUS_CONTEXT = "Verified release tree"


def gh_json(path: str) -> dict | list:
    result = subprocess.run(["gh", "api", path], capture_output=True, check=False)
    if result.returncode:
        raise ValueError(result.stderr.decode(errors="replace").strip() or f"GitHub API failed: {path}")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise ValueError(f"GitHub API returned invalid JSON for {path}: {error}") from error


def validate_run(run: dict, repository: str, merge_sha: str) -> list[str]:
    errors: list[str] = []
    if run.get("path") != WORKFLOW_PATH or run.get("event") != "push":
        errors.append("release attestation came from the wrong workflow or event")
    if run.get("head_sha") != merge_sha or run.get("conclusion") != "success":
        errors.append("release attestation workflow is stale or unsuccessful")
    if (run.get("repository") or {}).get("full_name") != repository:
        errors.append("release attestation workflow belongs to another repository")
    return errors


def validate_status(statuses: list[dict], run_url: str) -> list[str]:
    status = next((item for item in statuses if item.get("context") == STATUS_CONTEXT), None)
    if not status or status.get("state") != "success":
        return ["merged commit lacks the latest successful release-tree status"]
    errors: list[str] = []
    if (status.get("creator") or {}).get("login") != "github-actions[bot]":
        errors.append("release-tree status has the wrong creator")
    if status.get("target_url") != run_url:
        errors.append("release-tree status does not target the exact verified workflow run")
    return errors


def download_artifact(repository: str, run_id: int, merge_sha: str) -> tuple[dict, str]:
    payload = gh_json(f"repos/{repository}/actions/runs/{run_id}/artifacts")
    artifacts = payload.get("artifacts", []) if isinstance(payload, dict) else []
    name = f"release-attestation-{merge_sha}"
    matches = [item for item in artifacts if item.get("name") == name and not item.get("expired")]
    if len(matches) != 1:
        raise ValueError("exactly one unexpired merged-tree attestation artifact is required")
    result = subprocess.run(
        ["gh", "api", f"repos/{repository}/actions/artifacts/{matches[0]['id']}/zip"],
        capture_output=True,
        check=False,
    )
    if result.returncode:
        raise ValueError(result.stderr.decode(errors="replace").strip() or "could not download release attestation")
    archive_digest = hashlib.sha256(result.stdout).hexdigest()
    with zipfile.ZipFile(BytesIO(result.stdout)) as archive:
        files = [item for item in archive.namelist() if item.endswith("release-attestation.json")]
        if len(files) != 1:
            raise ValueError("release artifact lacks one attestation JSON file")
        return json.loads(archive.read(files[0])), archive_digest


def collect(repository: str, merge_sha: str, verified_head: str, wait_seconds: int) -> tuple[list[str], dict]:
    deadline = time.monotonic() + wait_seconds
    run: dict | None = None
    while time.monotonic() <= deadline:
        payload = gh_json(
            f"repos/{repository}/actions/workflows/release-tree-attestation.yml/runs"
            f"?event=push&head_sha={merge_sha}&per_page=20"
        )
        runs = payload.get("workflow_runs", []) if isinstance(payload, dict) else []
        run = next((item for item in runs if item.get("head_sha") == merge_sha), None)
        if run and run.get("status") == "completed":
            break
        if wait_seconds == 0:
            break
        time.sleep(5)
    if not run:
        return ["exact merged-tree workflow run is unavailable"], {}
    errors = validate_run(run, repository, merge_sha)
    run_id = int(run.get("id") or 0)
    run_url = str(run.get("html_url") or "")
    statuses = gh_json(f"repos/{repository}/commits/{merge_sha}/statuses?per_page=100")
    if not isinstance(statuses, list):
        errors.append("merged commit statuses returned an invalid payload")
        statuses = []
    errors.extend(validate_status(statuses, run_url))
    attestation: dict = {}
    archive_digest = ""
    if not errors:
        try:
            attestation, archive_digest = download_artifact(repository, run_id, merge_sha)
        except (ValueError, json.JSONDecodeError, zipfile.BadZipFile) as error:
            errors.append(str(error))
    if attestation:
        if attestation.get("status") != "PASS":
            errors.append("release attestation artifact did not pass")
        if attestation.get("main_commit") != merge_sha or attestation.get("verified_head") != verified_head:
            errors.append("release attestation artifact is bound to another merge or verified head")
    proof = {
        "schema_version": 1,
        "status": "PASS" if not errors else "FAIL",
        "repository": repository,
        "merge_sha": merge_sha,
        "verified_head": verified_head,
        "workflow_path": run.get("path"),
        "workflow_event": run.get("event"),
        "workflow_run_id": run_id,
        "workflow_run_url": run_url,
        "artifact_zip_sha256": archive_digest,
        "attestation": attestation,
        "errors": errors,
    }
    return errors, proof


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--merge-sha", required=True)
    parser.add_argument("--verified-head", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--wait-seconds", type=int, default=600)
    args = parser.parse_args()
    try:
        errors, proof = collect(args.repo, args.merge_sha, args.verified_head, args.wait_seconds)
    except ValueError as error:
        errors, proof = [str(error)], {"schema_version": 1, "status": "FAIL", "errors": [str(error)]}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(proof, indent=2) + "\n", encoding="utf-8")
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1
    print(f"Merged tree verified by exact workflow run: {args.merge_sha}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
