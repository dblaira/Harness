#!/usr/bin/env python3
"""Validate commit-bound local handoff evidence and enforce it from a Codex Stop hook."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


PRODUCT_PREFIXES = (
    "Sources/",
    "Tests/HarnessTests/",
    "Tests/HarnessUITests/",
    "Packages/OntologyKit/Sources/",
    "Packages/OntologyKit/Tests/",
)
PRODUCT_FILES = {"project.yml"}
COMPLETION_WORDS = re.compile(
    r"\b(done|fixed|implemented|ready|verified|working|shipped|complete|completed)\b",
    re.IGNORECASE,
)
NON_COMPLETION = re.compile(
    r"\b(not done|not ready|not verified|unverified|incomplete|blocked|failed|could not)\b",
    re.IGNORECASE,
)


def run_git(root: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *args], cwd=root, text=True, capture_output=True, check=False
    )
    if result.returncode:
        return ""
    return result.stdout.strip()


def current_commit(root: Path) -> str:
    return run_git(root, "rev-parse", "HEAD")


def changed_files(root: Path) -> set[str]:
    files: set[str] = set()
    base = os.environ.get("HARNESS_GATE_BASE", "origin/main")
    if run_git(root, "rev-parse", "--verify", base):
        files.update(run_git(root, "diff", "--name-only", f"{base}...HEAD").splitlines())
    else:
        files.update(run_git(root, "diff", "--name-only", "HEAD^").splitlines())
    files.update(run_git(root, "diff", "--name-only", "HEAD").splitlines())
    files.update(run_git(root, "ls-files", "--others", "--exclude-standard").splitlines())
    return {item for item in files if item}


def product_changes(root: Path) -> list[str]:
    return sorted(
        path
        for path in changed_files(root)
        if path in PRODUCT_FILES or path.startswith(PRODUCT_PREFIXES)
    )


def resolve_artifact(root: Path, value: Any) -> Path | None:
    if not isinstance(value, str) or not value.strip():
        return None
    path = Path(value).expanduser()
    return path if path.is_absolute() else root / path


def sha256_path(path: Path) -> str:
    digest = hashlib.sha256()
    if path.is_file():
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        return digest.hexdigest()
    for child in sorted(item for item in path.rglob("*") if item.is_file()):
        digest.update(str(child.relative_to(path)).encode("utf-8"))
        with child.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
    return digest.hexdigest()


def validate_manifest(root: Path, manifest_path: Path) -> list[str]:
    errors: list[str] = []
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        return [f"cannot read handoff manifest: {error}"]

    expected_commit = current_commit(root)
    if manifest.get("schema_version") != 1:
        errors.append("schema_version must be 1")
    if manifest.get("status") != "PASS":
        errors.append("manifest status must be PASS")
    if manifest.get("commit") != expected_commit:
        errors.append("manifest commit does not match HEAD")
    for key in (
        "requirement_verbatim",
        "visible_surface",
        "expected_visible_result",
        "observed_visible_result",
        "app_bundle",
        "app_cdhash",
        "app_team_identifier",
        "git_tree",
        "verifier",
        "created_at",
    ):
        if not isinstance(manifest.get(key), str) or not manifest[key].strip():
            errors.append(f"{key} is required")
    if manifest.get("codesign_verified") is not True:
        errors.append("signed app verification did not pass")
    if manifest.get("app_team_identifier") != "7FKUS5M5QS":
        errors.append("signed app team identifier does not match Adam's Harness team")
    if manifest.get("git_tree") != run_git(root, "rev-parse", "HEAD^{tree}"):
        errors.append("manifest git tree does not match HEAD")
    if not isinstance(manifest.get("app_pid"), int) or manifest.get("app_pid", 0) <= 0:
        errors.append("a live signed app PID is required")
    if manifest.get("working_tree_clean") is not True:
        errors.append("working tree was not clean when evidence was captured")
    if run_git(root, "status", "--porcelain", "--untracked-files=normal"):
        errors.append("working tree is not currently clean")

    tests = manifest.get("tests")
    required_tests = {"macos-unit-tests", "macos-ui-tests"}
    passed_tests = {
        test.get("name")
        for test in tests or []
        if isinstance(test, dict) and test.get("status") == "PASS"
    }
    if not required_tests.issubset(passed_tests):
        errors.append("both macOS unit and UI tests must pass without skips")

    review = manifest.get("sol_review") or {}
    if review.get("status") != "PASS" or not review.get("check_run_url"):
        errors.append("a passing commit-bound GPT-5.6 Sol check is required")

    artifacts = manifest.get("artifacts") or {}
    hashes = manifest.get("artifact_sha256") or {}
    for name in ("screenshot", "video", "unit_xcresult", "ui_xcresult"):
        path = resolve_artifact(root, artifacts.get(name))
        if path is None or not path.exists():
            errors.append(f"artifact is missing: {name}")
        elif path.is_file() and path.stat().st_size == 0:
            errors.append(f"artifact is empty: {name}")
        elif hashes.get(name) != sha256_path(path):
            errors.append(f"artifact hash does not match: {name}")
    return errors


def manifest_path(root: Path) -> Path:
    return root / ".local-artifacts" / "release-gate" / current_commit(root) / "manifest.json"


def completion_claim(message: str) -> bool:
    return bool(COMPLETION_WORDS.search(message)) and not bool(NON_COMPLETION.search(message))


def hook(root: Path, payload: dict[str, Any]) -> dict[str, Any]:
    message = str(payload.get("last_assistant_message", ""))
    changes = product_changes(root)
    if not changes:
        return {"continue": True}
    if NON_COMPLETION.search(message) and "BLOCKED:" in message.upper():
        return {"continue": True}
    path = manifest_path(root)
    errors = validate_manifest(root, path) if path.exists() else ["handoff manifest is absent"]
    if not errors:
        return {"continue": True}
    changed = ", ".join(changes[:6])
    reason = (
        "Task completion is blocked. Run the signed local handoff gate and bind visible "
        f"evidence to commit {current_commit(root)}. Product changes: {changed}. "
        + " ".join(errors)
    )
    return {"decision": "block", "reason": reason}


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    validate_parser = subparsers.add_parser("validate")
    validate_parser.add_argument("--manifest", type=Path)
    subparsers.add_parser("hook")
    args = parser.parse_args()
    root = Path(run_git(Path.cwd(), "rev-parse", "--show-toplevel") or Path.cwd()).resolve()

    if args.command == "validate":
        path = (args.manifest or manifest_path(root)).resolve()
        errors = validate_manifest(root, path)
        if errors:
            for error in errors:
                print(f"- {error}", file=sys.stderr)
            return 1
        print(f"Handoff evidence passed for {current_commit(root)}: {path}")
        return 0

    try:
        payload = json.load(sys.stdin)
    except json.JSONDecodeError:
        payload = {}
    print(json.dumps(hook(root, payload)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
