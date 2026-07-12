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
import tempfile
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
PRODUCT_FILES.update(
    {
        "Packages/OntologyKit/Package.swift",
        "Packages/OntologyKit/Package.resolved",
    }
)
GATE_PREFIXES = (
    ".github/workflows/",
    ".github/codex/",
    "script/",
    "scripts/tests/",
    "scripts/validate_",
    "scripts/verify_",
)
GATE_FILES = {
    ".github/acceptance-contract.json",
    ".github/pull_request_template.md",
    ".cursor/rules/ios-main-only.mdc",
    ".cursor/rules/stack-ios.mdc",
    "scripts/lint_changed_swift.sh",
    "scripts/release_gate.py",
    "scripts/resolve_harness_repo.py",
    "scripts/verify_app_identity.py",
    "scripts/verify_codex_auth.py",
    "scripts/verify_codex_runtime.py",
}
COMPLETION_WORDS = re.compile(
    r"\b(done|fixed|implemented|installed|ready|verified|working|works|passes|passed|"
    r"resolved|successful|succeeded|shipped|complete|completed)\b",
    re.IGNORECASE,
)
NON_COMPLETION = re.compile(
    r"\b(not done|not ready|not verified|unverified|incomplete|blocked|failed|could not)\b",
    re.IGNORECASE,
)
UI_TEST_PATTERN = re.compile(r"^HarnessUITests/[A-Za-z_][A-Za-z0-9_]*/test[A-Za-z0-9_]+$")
USER_QUESTION = re.compile(
    r"^(?:adam[,:—\s]+)?(?:who|what|when|where|why|how|which|should|could|would|"
    r"can|may|is|are|do|does|did|will)\b.*\?\s*$",
    re.IGNORECASE | re.DOTALL,
)


class GitInspectionError(RuntimeError):
    """Raised when release evidence cannot safely inspect repository state."""


def run_git(root: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *args], cwd=root, text=True, capture_output=True, check=False
    )
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip() or "unknown git error"
        raise GitInspectionError(f"git {' '.join(args)} failed: {detail}")
    return result.stdout.strip()


def current_commit(root: Path) -> str:
    return run_git(root, "rev-parse", "HEAD")


def changed_files(root: Path) -> set[str]:
    files: set[str] = set()
    base = os.environ.get("HARNESS_GATE_BASE", "origin/main")
    run_git(root, "rev-parse", "--verify", base)
    files.update(run_git(root, "diff", "--name-only", f"{base}...HEAD").splitlines())
    files.update(run_git(root, "diff", "--name-only", "HEAD").splitlines())
    files.update(run_git(root, "ls-files", "--others", "--exclude-standard").splitlines())
    return {item for item in files if item}


def product_changes(root: Path) -> list[str]:
    return sorted(
        path
        for path in changed_files(root)
        if path in PRODUCT_FILES or path.startswith(PRODUCT_PREFIXES)
    )


def guarded_changes(root: Path) -> list[str]:
    return sorted(
        path
        for path in changed_files(root)
        if path in PRODUCT_FILES
        or path in GATE_FILES
        or path.startswith(PRODUCT_PREFIXES)
        or path.startswith(GATE_PREFIXES)
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


def run_command(*args: str, cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        cwd=cwd,
        text=True,
        capture_output=True,
        check=False,
        timeout=30,
    )


def validate_png(path: Path) -> list[str]:
    try:
        data = path.read_bytes()
    except OSError as error:
        return [f"cannot read PNG evidence: {error}"]
    if len(data) < 1024 or not data.startswith(b"\x89PNG\r\n\x1a\n"):
        return [f"image evidence is not a nontrivial PNG: {path.name}"]
    return []


def validate_quicktime(path: Path) -> list[str]:
    try:
        with path.open("rb") as handle:
            header = handle.read(64)
        size = path.stat().st_size
    except OSError as error:
        return [f"cannot read video evidence: {error}"]
    if size < 100_000 or b"ftyp" not in header:
        return ["video evidence is not a nontrivial QuickTime/MP4 recording"]
    return []


def validate_xcresult(
    path: Path,
    *,
    required_test: str | None = None,
    required_bundle: str | None = None,
    expected_screenshot: Path | None = None,
) -> list[str]:
    validator = Path(__file__).with_name("validate_xcresult.py")
    args = [sys.executable, str(validator), "--xcresult", str(path)]
    if required_bundle:
        args.extend(("--required-bundle", required_bundle))
        result = run_command(*args)
        return [] if result.returncode == 0 else [result.stderr.strip() or result.stdout.strip()]
    if not required_test or expected_screenshot is None:
        return ["trusted xcresult validation lacks its expected test or screenshot"]
    with tempfile.TemporaryDirectory(prefix="harness-manifest-") as directory:
        exported = Path(directory) / "visible.png"
        args.extend(("--required-test", required_test, "--max-duration", "55", "--screenshot-output", str(exported)))
        result = run_command(*args)
        if result.returncode:
            return [result.stderr.strip() or result.stdout.strip()]
        if sha256_path(exported) != sha256_path(expected_screenshot):
            return ["PNG evidence does not match the named screenshot attachment in xcresult"]
    return []


def validate_manifest(root: Path, manifest_path: Path) -> list[str]:
    errors: list[str] = []
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        return [f"cannot read handoff manifest: {error}"]
    if not isinstance(manifest, dict):
        return ["handoff manifest must be a JSON object"]

    try:
        expected_commit = current_commit(root)
        expected_tree = run_git(root, "rev-parse", "HEAD^{tree}")
        current_status = run_git(root, "status", "--porcelain", "--untracked-files=normal")
    except GitInspectionError as error:
        return [str(error)]
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
        "ui_test_identifier",
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
    if manifest.get("git_tree") != expected_tree:
        errors.append("manifest git tree does not match HEAD")
    if not isinstance(manifest.get("app_pid"), int) or manifest.get("app_pid", 0) <= 0:
        errors.append("a live signed app PID is required")
    if manifest.get("working_tree_clean") is not True:
        errors.append("working tree was not clean when evidence was captured")
    if current_status:
        errors.append("working tree is not currently clean")
    ui_test_identifier = manifest.get("ui_test_identifier", "")
    if not isinstance(ui_test_identifier, str) or not UI_TEST_PATTERN.fullmatch(ui_test_identifier):
        errors.append("manifest does not name an exact HarnessUITests requirement test")
    acceptance_test_identifier = manifest.get("acceptance_test_identifier", "")
    if (
        acceptance_test_identifier != "INFRASTRUCTURE_ONLY"
        and acceptance_test_identifier != ui_test_identifier
    ):
        errors.append("executed UI test does not match the reviewed acceptance contract")
    contract_path = root / ".github" / "acceptance-contract.json"
    try:
        contract = json.loads(contract_path.read_text(encoding="utf-8"))
        canonical = json.dumps(contract, sort_keys=True, separators=(",", ":")).encode("utf-8")
        expected_contract_digest = hashlib.sha256(canonical).hexdigest()
    except (OSError, json.JSONDecodeError) as error:
        errors.append(f"cannot validate checked-in acceptance contract: {error}")
        contract = {}
        expected_contract_digest = ""
    if manifest.get("contract_digest") != expected_contract_digest:
        errors.append("manifest acceptance contract digest does not match the checked-in contract")
    for manifest_key, contract_key in (
        ("requirement_verbatim", "requirement_verbatim"),
        ("visible_surface", "visible_surface"),
        ("expected_visible_result", "expected_visible_result"),
        ("acceptance_test_identifier", "ui_test_identifier"),
        ("final_accessibility_identifier", "final_accessibility_identifier"),
    ):
        if manifest.get(manifest_key) != contract.get(contract_key):
            errors.append(f"manifest {manifest_key} does not match the checked-in contract")

    tests = manifest.get("tests")
    if not isinstance(tests, list):
        errors.append("tests must be a list")
        tests = []
    required_tests = {
        "macos-unit-tests",
        "macos-ui-tests",
        "final-relaunch-ui-test",
        "live-satisfaction-gate",
    }
    passed_tests = {
        test.get("name")
        for test in tests or []
        if isinstance(test, dict) and test.get("status") == "PASS"
    }
    if not required_tests.issubset(passed_tests):
        errors.append("both macOS unit and UI tests must pass without skips")
    ui_results = [
        test for test in tests or []
        if isinstance(test, dict) and test.get("name") == "macos-ui-tests"
    ]
    if len(ui_results) != 1 or ui_results[0].get("test_identifier") != ui_test_identifier:
        errors.append("UI test result is not bound to the manifest requirement test")
    final_results = [
        test for test in tests or []
        if isinstance(test, dict) and test.get("name") == "final-relaunch-ui-test"
    ]
    final_attach_test = ui_test_identifier
    if len(final_results) != 1 or final_results[0].get("test_identifier") != final_attach_test:
        errors.append("final relaunch did not rerun the exact manifest requirement test")

    review = manifest.get("sol_review") or {}
    if not isinstance(review, dict):
        errors.append("sol_review must be an object")
        review = {}
    if review.get("status") != "PASS" or not review.get("check_run_url"):
        errors.append("a passing commit-bound GPT-5.6 Sol check is required")

    artifacts = manifest.get("artifacts") or {}
    hashes = manifest.get("artifact_sha256") or {}
    if not isinstance(artifacts, dict):
        errors.append("artifacts must be an object")
        artifacts = {}
    if not isinstance(hashes, dict):
        errors.append("artifact_sha256 must be an object")
        hashes = {}
    for name in (
        "screenshot",
        "video",
        "unit_xcresult",
        "ui_xcresult",
        "final_screenshot",
        "final_ui_screenshot",
        "final_ui_xcresult",
        "running_app_proof",
        "satisfaction_artifact",
        "app_bundle",
        "app_identity",
    ):
        path = resolve_artifact(root, artifacts.get(name))
        if path is None or not path.exists():
            errors.append(f"artifact is missing: {name}")
        elif path.is_file() and path.stat().st_size == 0:
            errors.append(f"artifact is empty: {name}")
        elif hashes.get(name) != sha256_path(path):
            errors.append(f"artifact hash does not match: {name}")
        elif name != "app_bundle" and manifest_path.parent.resolve() not in path.resolve().parents:
            errors.append(f"artifact is outside the commit-bound evidence directory: {name}")

    screenshot = resolve_artifact(root, artifacts.get("screenshot"))
    final_screenshot = resolve_artifact(root, artifacts.get("final_screenshot"))
    final_ui_screenshot = resolve_artifact(root, artifacts.get("final_ui_screenshot"))
    video = resolve_artifact(root, artifacts.get("video"))
    unit_xcresult = resolve_artifact(root, artifacts.get("unit_xcresult"))
    ui_xcresult = resolve_artifact(root, artifacts.get("ui_xcresult"))
    final_ui_xcresult = resolve_artifact(root, artifacts.get("final_ui_xcresult"))
    satisfaction = resolve_artifact(root, artifacts.get("satisfaction_artifact"))
    app_bundle = resolve_artifact(root, artifacts.get("app_bundle"))
    app_identity = resolve_artifact(root, artifacts.get("app_identity"))
    running_app_proof = resolve_artifact(root, artifacts.get("running_app_proof"))
    if screenshot and screenshot.is_file():
        errors.extend(validate_png(screenshot))
    if final_screenshot and final_screenshot.is_file():
        errors.extend(validate_png(final_screenshot))
    if final_ui_screenshot and final_ui_screenshot.is_file():
        errors.extend(validate_png(final_ui_screenshot))
    if video and video.is_file():
        errors.extend(validate_quicktime(video))
    if unit_xcresult and unit_xcresult.is_dir():
        errors.extend(validate_xcresult(unit_xcresult, required_bundle="HarnessTests"))
    if ui_xcresult and ui_xcresult.is_dir() and screenshot and screenshot.is_file():
        errors.extend(validate_xcresult(ui_xcresult, required_test=ui_test_identifier, expected_screenshot=screenshot))
    if final_ui_xcresult and final_ui_xcresult.is_dir() and final_ui_screenshot and final_ui_screenshot.is_file():
        errors.extend(validate_xcresult(final_ui_xcresult, required_test=final_attach_test, expected_screenshot=final_ui_screenshot))
    if satisfaction and satisfaction.is_file():
        text = satisfaction.read_text(encoding="utf-8", errors="replace")
        required_markers = (
            f"- Commit: {expected_commit}",
            "- Fuseki graph health: healthy",
            "## Answer as produced",
        )
        if satisfaction.stat().st_size < 500 or any(marker not in text for marker in required_markers):
            errors.append("live satisfaction artifact is missing commit-bound healthy Fuseki proof and answer")
        match = re.search(r"- Fuseki authority hits: (\d+)", text)
        if not match or int(match.group(1)) < 1:
            errors.append("live satisfaction artifact has no Fuseki-sourced authority hit")
    if app_bundle and app_bundle.is_dir():
        verify = run_command("/usr/bin/codesign", "--verify", "--deep", "--strict", str(app_bundle))
        detail = run_command("/usr/bin/codesign", "-dvvv", str(app_bundle))
        signature = detail.stderr + detail.stdout
        team = re.search(r"^TeamIdentifier=(.+)$", signature, re.MULTILINE)
        cdhash = re.search(r"^CDHash=(.+)$", signature, re.MULTILINE)
        if verify.returncode or not team or team.group(1) != "7FKUS5M5QS":
            errors.append("current app bundle does not pass trusted deep codesign verification")
        if not cdhash or cdhash.group(1) != manifest.get("app_cdhash"):
            errors.append("current app CDHash does not match the manifest")
        executable = app_bundle / "Contents" / "MacOS" / "Harness"
        if not executable.is_file():
            errors.append("current app bundle lacks the Harness executable")
        if app_identity and app_identity.is_file():
            validator = Path(__file__).with_name("verify_app_identity.py")
            with tempfile.TemporaryDirectory(prefix="harness-identity-") as directory:
                fresh_proof = Path(directory) / "identity.json"
                identity_result = run_command(
                    sys.executable,
                    str(validator),
                    "--app",
                    str(app_bundle),
                    "--output",
                    str(fresh_proof),
                )
                if identity_result.returncode:
                    errors.append(identity_result.stdout.strip() or identity_result.stderr.strip())
                elif sha256_path(fresh_proof) != sha256_path(app_identity):
                    errors.append("app identity proof does not match current signature and entitlements")
    pid = manifest.get("app_pid")
    if isinstance(pid, int) and pid > 0 and app_bundle:
        process = run_command("/bin/ps", "-p", str(pid), "-o", "command=")
        expected_command = str(app_bundle / "Contents" / "MacOS" / "Harness")
        if process.returncode or not process.stdout.strip().startswith(expected_command):
            errors.append("manifest PID is not the current signed Harness app process")
        if running_app_proof and running_app_proof.is_file():
            try:
                proof = json.loads(running_app_proof.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                proof = {}
            if (
                proof.get("status") != "PASS"
                or proof.get("pid") != pid
                or proof.get("accessibility_pid") != pid
                or proof.get("bundle_identifier") != "com.adamblair.Harness"
                or proof.get("executable") != expected_command
                or proof.get("accessibility_identifier") != manifest.get("final_accessibility_identifier")
            ):
                errors.append("final Accessibility proof is not bound to the exact candidate PID and requirement")

    try:
        repo = run_command("gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner", cwd=root)
        pulls = run_command("gh", "api", f"repos/{repo.stdout.strip()}/commits/{expected_commit}/pulls", cwd=root)
        pull_payload = json.loads(pulls.stdout)
        open_pull = next((item for item in pull_payload if item.get("state") == "open"), None)
        if not open_pull:
            errors.append("current commit has no open pull request for contract validation")
        else:
            sys.path.insert(0, str(Path(__file__).parent))
            import validate_acceptance_contract as acceptance  # type: ignore
            body_digest = acceptance.pr_contract_digest(str(open_pull.get("body") or ""))
            if body_digest != manifest.get("pr_contract_digest"):
                errors.append("manifest pull-request contract digest is stale")
            contract_errors = acceptance.validate_handoff_contract(
                contract,
                str(open_pull.get("body") or ""),
                repo=repo.stdout.strip(),
                pr_number=int(open_pull.get("number")),
                base_sha=str((open_pull.get("base") or {}).get("sha") or ""),
            )
            errors.extend(f"current acceptance contract: {error}" for error in contract_errors)
        status = run_command("gh", "api", f"repos/{repo.stdout.strip()}/commits/{expected_commit}/statuses?per_page=100", cwd=root)
        status_payload = json.loads(status.stdout)
        latest = next(
            (item for item in status_payload if item.get("context") == "GPT-5.6 Sol review"),
            None,
        )
        digest_marker = f"contract:{expected_contract_digest[:12]}"
        if (
            status.returncode
            or not latest
            or latest.get("state") != "success"
            or (latest.get("creator") or {}).get("login") != "dblaira"
            or digest_marker not in str(latest.get("description", ""))
            or latest.get("target_url") != review.get("check_run_url")
        ):
            errors.append("current GPT-5.6 Sol status is not successful and bound to this contract")
    except (json.JSONDecodeError, StopIteration):
        errors.append("cannot validate current GPT-5.6 Sol status")
    return errors


def manifest_path(root: Path) -> Path:
    return root / ".local-artifacts" / "release-gate" / current_commit(root) / "manifest.json"


def completion_claim(message: str) -> bool:
    return bool(COMPLETION_WORDS.search(message)) and not bool(NON_COMPLETION.search(message))


def explicit_blocked_exit(message: str) -> bool:
    return message.lstrip().upper().startswith("BLOCKED:")


def explicit_user_question(message: str) -> bool:
    return (
        bool(message.strip())
        and bool(USER_QUESTION.fullmatch(message.strip()))
        and not completion_claim(message)
    )


def hook(root: Path, payload: dict[str, Any]) -> dict[str, Any]:
    message = str(payload.get("last_assistant_message", ""))
    try:
        changes = guarded_changes(root)
    except GitInspectionError as error:
        return {"decision": "block", "reason": f"Task completion is blocked. {error}"}
    if not changes:
        return {"continue": True}
    if explicit_blocked_exit(message) or explicit_user_question(message):
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
    try:
        root = Path(run_git(Path.cwd(), "rev-parse", "--show-toplevel")).resolve()
    except GitInspectionError:
        root = Path.cwd().resolve()

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
