#!/usr/bin/env python3
"""Run commit-bound regression checks across the Understood suite on Adam's Mac."""

from __future__ import annotations

import argparse
import fcntl
import glob
import json
import os
import platform
import shutil
import signal
import socket
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


PROFILE_LAYERS = {
    "smoke": {"smoke"},
    "full": {"smoke", "full"},
    "stress": {"smoke", "full", "stress"},
}
MANIFEST_FIELDS = {"schema_version", "suite_name", "apps"}
APP_FIELDS = {"id", "name", "repo_url", "branch", "local_candidates", "checks"}
CHECK_FIELDS = {
    "id",
    "name",
    "kind",
    "profiles",
    "command",
    "working_directory",
    "environment",
    "timeout_seconds",
    "stressable",
    "pattern",
    "path",
    "needle",
    "coverage_requirement",
}


class ManifestError(ValueError):
    pass


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def run_id() -> str:
    return datetime.now().astimezone().strftime("%Y-%m-%dT%H-%M-%S%z")


def validate_manifest(manifest: dict[str, Any]) -> None:
    unknown = set(manifest) - MANIFEST_FIELDS
    if unknown:
        raise ManifestError(f"unknown manifest fields: {', '.join(sorted(unknown))}")
    if manifest.get("schema_version") != 1:
        raise ManifestError("schema_version must be 1")
    apps = manifest.get("apps")
    if not isinstance(apps, list) or not apps:
        raise ManifestError("apps must be a non-empty list")
    app_ids: set[str] = set()
    for app in apps:
        if not isinstance(app, dict):
            raise ManifestError("every app must be an object")
        unknown = set(app) - APP_FIELDS
        if unknown:
            raise ManifestError(f"{app.get('id', 'app')}: unknown fields: {', '.join(sorted(unknown))}")
        for key in ("id", "name", "repo_url", "branch"):
            if not isinstance(app.get(key), str) or not app[key]:
                raise ManifestError(f"app {key} must be a non-empty string")
        if app["id"] in app_ids:
            raise ManifestError(f"duplicate app id: {app['id']}")
        app_ids.add(app["id"])
        checks = app.get("checks")
        if not isinstance(checks, list) or not checks:
            raise ManifestError(f"{app['id']}: checks must be a non-empty list")
        check_ids: set[str] = set()
        for check in checks:
            if not isinstance(check, dict):
                raise ManifestError(f"{app['id']}: every check must be an object")
            unknown = set(check) - CHECK_FIELDS
            if unknown:
                raise ManifestError(
                    f"{app['id']}/{check.get('id', 'check')}: unknown fields: {', '.join(sorted(unknown))}"
                )
            for key in ("id", "name", "kind"):
                if not isinstance(check.get(key), str) or not check[key]:
                    raise ManifestError(f"{app['id']}: check {key} must be a non-empty string")
            if check["id"] in check_ids:
                raise ManifestError(f"{app['id']}: duplicate check id: {check['id']}")
            check_ids.add(check["id"])
            profiles = check.get("profiles")
            if not isinstance(profiles, list) or not profiles or not set(profiles) <= set(PROFILE_LAYERS):
                raise ManifestError(f"{app['id']}/{check['id']}: invalid profiles")
            kind = check["kind"]
            if kind == "command":
                command = check.get("command")
                if not isinstance(command, list) or not command or not all(isinstance(item, str) for item in command):
                    raise ManifestError(f"{app['id']}/{check['id']}: command must be a string list")
            elif kind == "path_glob":
                if not isinstance(check.get("pattern"), str):
                    raise ManifestError(f"{app['id']}/{check['id']}: pattern is required")
            elif kind == "text_contains":
                if not isinstance(check.get("path"), str) or not isinstance(check.get("needle"), str):
                    raise ManifestError(f"{app['id']}/{check['id']}: path and needle are required")
            else:
                raise ManifestError(f"{app['id']}/{check['id']}: unsupported kind {kind}")


def load_manifest(path: Path) -> dict[str, Any]:
    manifest = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(manifest, dict):
        raise ManifestError("manifest must be a JSON object")
    validate_manifest(manifest)
    return manifest


def selected_for_profile(check: dict[str, Any], profile: str) -> bool:
    return bool(set(check["profiles"]) & PROFILE_LAYERS[profile])


def substitute(value: str, variables: dict[str, str]) -> str:
    result = value
    for key, replacement in variables.items():
        result = result.replace("{" + key + "}", replacement)
    return result


def run_process(
    command: list[str],
    *,
    cwd: Path,
    environment: dict[str, str],
    timeout_seconds: int,
    log_path: Path,
) -> tuple[int, bool, float]:
    started = time.monotonic()
    timed_out = False
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("w", encoding="utf-8") as log:
        log.write("COMMAND: " + " ".join(command) + "\n")
        log.write(f"WORKING_DIRECTORY: {cwd}\n")
        log.flush()
        try:
            process = subprocess.Popen(
                command,
                cwd=cwd,
                env=environment,
                stdout=log,
                stderr=subprocess.STDOUT,
                text=True,
                start_new_session=True,
            )
        except OSError as error:
            log.write(f"LAUNCH_ERROR: {error}\n")
            return 127, False, time.monotonic() - started
        try:
            return_code = process.wait(timeout=timeout_seconds)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(process.pid, signal.SIGTERM)
            try:
                return_code = process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                return_code = process.wait()
            log.write(f"TIMEOUT_AFTER_SECONDS: {timeout_seconds}\n")
    return return_code, timed_out, time.monotonic() - started


def git_output(git_dir: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", f"--git-dir={git_dir}", *args],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or f"git {' '.join(args)} failed")
    return result.stdout.strip()


def prepare_worktree(app: dict[str, Any], cache_root: Path, worktree_root: Path, log_path: Path, no_fetch: bool) -> tuple[Path, str]:
    mirror = cache_root / "repos" / f"{app['id']}.git"
    mirror.parent.mkdir(parents=True, exist_ok=True)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("w", encoding="utf-8") as log:
        if not mirror.exists():
            source = app["repo_url"]
            for candidate in app.get("local_candidates", []):
                candidate_path = Path(candidate).expanduser()
                if (candidate_path / ".git").exists():
                    source = str(candidate_path)
                    break
            clone = subprocess.run(
                ["git", "clone", "--bare", source, str(mirror)],
                text=True,
                stdout=log,
                stderr=subprocess.STDOUT,
                check=False,
            )
            if clone.returncode:
                raise RuntimeError(f"could not initialize repository cache; see {log_path}")
            subprocess.run(
                ["git", f"--git-dir={mirror}", "remote", "set-url", "origin", app["repo_url"]],
                text=True,
                stdout=log,
                stderr=subprocess.STDOUT,
                check=True,
            )
        if not no_fetch:
            refspec = f"+refs/heads/{app['branch']}:refs/remotes/origin/{app['branch']}"
            fetch = subprocess.run(
                ["git", f"--git-dir={mirror}", "fetch", "--prune", "origin", refspec],
                text=True,
                stdout=log,
                stderr=subprocess.STDOUT,
                check=False,
            )
            if fetch.returncode:
                raise RuntimeError(f"could not fetch exact {app['branch']} commit; see {log_path}")
    remote_ref = f"refs/remotes/origin/{app['branch']}"
    try:
        sha = git_output(mirror, "rev-parse", f"{remote_ref}^{{commit}}")
    except RuntimeError:
        if not no_fetch:
            raise
        # A newly initialized local bare cache has refs/heads/* before its
        # first network fetch. --no-fetch may use that exact local snapshot,
        # but never invent a different commit.
        sha = git_output(mirror, "rev-parse", f"refs/heads/{app['branch']}^{{commit}}")
    subprocess.run(
        ["git", f"--git-dir={mirror}", "worktree", "prune"],
        text=True,
        capture_output=True,
        check=False,
    )
    worktree = worktree_root / app["id"]
    worktree.parent.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(
        ["git", f"--git-dir={mirror}", "worktree", "add", "--detach", str(worktree), sha],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip())
    return worktree, sha


def remove_worktree(app_id: str, cache_root: Path, worktree: Path) -> None:
    mirror = cache_root / "repos" / f"{app_id}.git"
    subprocess.run(
        ["git", f"--git-dir={mirror}", "worktree", "remove", "--force", str(worktree)],
        text=True,
        capture_output=True,
        check=False,
    )
    if worktree.exists():
        shutil.rmtree(worktree, ignore_errors=True)


def coverage_check(check: dict[str, Any], worktree: Path) -> tuple[str, str]:
    if check["kind"] == "path_glob":
        matches = [Path(path) for path in glob.glob(str(worktree / check["pattern"]), recursive=True)]
        files = [path for path in matches if path.is_file()]
        if files:
            return "PASS", f"matched {len(files)} file(s)"
        return "GAP", check.get("coverage_requirement", "required coverage is missing")
    path = worktree / check["path"]
    try:
        content = path.read_text(encoding="utf-8")
    except OSError as error:
        return "GAP", f"cannot read {check['path']}: {error}"
    if check["needle"] in content:
        return "PASS", f"literal contract found in {check['path']}"
    return "GAP", check.get("coverage_requirement", "required visible assertion is missing")


def overall_status(app_results: list[dict[str, Any]]) -> str:
    statuses = {
        check["status"]
        for app in app_results
        for check in app.get("checks", [])
    }
    if "FAIL" in statuses or any(app.get("status") == "FAIL" for app in app_results):
        return "FAIL"
    if "GAP" in statuses:
        return "INCOMPLETE"
    return "PASS"


def markdown_report(result: dict[str, Any], report_dir: Path) -> str:
    lines = [
        "# Understood Suite Regression Patrol",
        "",
        f"# {result['status']}",
        "",
        f"- Run: `{result['run_id']}`",
        f"- Machine: `{result['machine']}`",
        f"- Profile: `{result['profile']}`",
        f"- Started: {result['started_at']}",
        f"- Finished: {result['finished_at']}",
        "",
        "## Exact suite result",
        "",
        "| App | Exact commit | Result |",
        "| --- | --- | --- |",
    ]
    for app in result["apps"]:
        commit = app.get("commit", "checkout failed")
        lines.append(f"| {app['name']} | `{commit}` | **{app['status']}** |")
    for app in result["apps"]:
        lines.extend(["", f"## {app['name']}", ""])
        if app.get("error"):
            lines.append(f"- **FAIL** — {app['error']}")
            continue
        for check in app["checks"]:
            detail = check.get("detail", "")
            duration = check.get("duration_seconds")
            measured = f" ({duration:.1f}s measured)" if isinstance(duration, (float, int)) else ""
            log = check.get("log")
            log_text = f" — [log]({log})" if log else ""
            lines.append(f"- **{check['status']}** — {check['name']}{measured}{log_text}")
            if detail:
                lines.append(f"  - {detail}")
    lines.extend([
        "",
        "## Meaning",
        "",
        "- `PASS` means every selected executable check and visible coverage contract passed on the exact commits above.",
        "- `FAIL` means a test, dependency, checkout, timeout, or live contract failed.",
        "- `INCOMPLETE` means the executable checks ran, but a named visible regression contract still has no test. It is never reported as green.",
        "",
        f"Raw evidence: [{report_dir}]({report_dir})",
    ])
    return "\n".join(lines) + "\n"


def notify(status: str, report_path: Path) -> None:
    title = "Understood Suite Regression Patrol"
    message = f"{status}: {report_path.name}"
    subprocess.run(
        ["osascript", "-e", f'display notification {json.dumps(message)} with title {json.dumps(title)}'],
        text=True,
        capture_output=True,
        check=False,
    )


def parse_args() -> argparse.Namespace:
    bundle_root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=bundle_root / "Regression" / "suite-regression.json")
    parser.add_argument("--profile", choices=sorted(PROFILE_LAYERS), default="smoke")
    parser.add_argument("--apps", help="comma-separated app ids")
    parser.add_argument("--stress-repetitions", type=int, default=3)
    parser.add_argument("--cache-root", type=Path, default=Path.home() / "Library/Caches/Harness/SuiteRegression")
    parser.add_argument("--output-root", type=Path, default=Path.home() / "Library/Logs/Harness/SuiteRegression")
    parser.add_argument("--no-fetch", action="store_true")
    parser.add_argument("--keep-worktrees", action="store_true")
    parser.add_argument("--notify", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if platform.system() != "Darwin":
        print("FAIL: suite regression patrol must run on Adam's Mac", file=sys.stderr)
        return 1
    if args.stress_repetitions < 1:
        print("FAIL: --stress-repetitions must be positive", file=sys.stderr)
        return 1
    try:
        manifest = load_manifest(args.manifest.resolve())
    except (OSError, json.JSONDecodeError, ManifestError) as error:
        print(f"FAIL: invalid suite regression manifest: {error}", file=sys.stderr)
        return 1
    selected_ids = set(filter(None, (args.apps or "").split(",")))
    apps = [app for app in manifest["apps"] if not selected_ids or app["id"] in selected_ids]
    missing_ids = selected_ids - {app["id"] for app in apps}
    if missing_ids:
        print(f"FAIL: unknown app ids: {', '.join(sorted(missing_ids))}", file=sys.stderr)
        return 1

    args.cache_root = args.cache_root.expanduser().resolve()
    args.output_root = args.output_root.expanduser().resolve()
    args.cache_root.mkdir(parents=True, exist_ok=True)
    lock_path = args.cache_root / "patrol.lock"
    lock = lock_path.open("w", encoding="utf-8")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("FAIL: another suite regression patrol is already running", file=sys.stderr)
        return 1

    current_run_id = run_id()
    report_dir = args.output_root / current_run_id
    report_dir.mkdir(parents=True, exist_ok=False)
    worktree_root = args.cache_root / "worktrees" / current_run_id
    bundle_root = Path(__file__).resolve().parents[1]
    result: dict[str, Any] = {
        "schema_version": 1,
        "suite": manifest["suite_name"],
        "run_id": current_run_id,
        "profile": args.profile,
        "machine": socket.gethostname(),
        "started_at": utc_now(),
        "apps": [],
    }
    print(f"REGRESSION_RUN: {current_run_id}", flush=True)
    print(f"PROFILE: {args.profile}", flush=True)
    prepared_worktrees: dict[str, Path] = {}
    try:
        # Check out the whole suite first. Some reviewed cross-repo fixtures,
        # such as SAVY's Understood exporter shape, are literal sibling paths.
        # Keeping every exact worktree present preserves that contract without
        # reading or altering Adam's active repositories.
        for app in apps:
            app_result: dict[str, Any] = {"id": app["id"], "name": app["name"], "status": "FAIL", "checks": []}
            result["apps"].append(app_result)
            app_artifacts = report_dir / app["id"]
            print(f"CHECKOUT_BEGIN: {app['name']}", flush=True)
            try:
                worktree, sha = prepare_worktree(
                    app,
                    args.cache_root,
                    worktree_root,
                    app_artifacts / "checkout.log",
                    args.no_fetch,
                )
                prepared_worktrees[app["id"]] = worktree
                app_result["commit"] = sha
                print(f"CHECKOUT_PASS: {app['name']} {sha}", flush=True)
            except Exception as error:
                app_result["error"] = str(error)
                app_result["status"] = "FAIL"
                print(f"CHECKOUT_FAIL: {app['id']}: {error}", flush=True)

        for app, app_result in zip(apps, result["apps"]):
            worktree = prepared_worktrees.get(app["id"])
            if worktree is None:
                continue
            app_artifacts = report_dir / app["id"]
            print(f"APP_BEGIN: {app['name']}", flush=True)
            try:
                variables = {
                    "worktree": str(worktree),
                    "artifact_dir": str(app_artifacts),
                    "bundle_root": str(bundle_root),
                }
                selected_checks = [check for check in app["checks"] if selected_for_profile(check, args.profile)]
                for check in selected_checks:
                    if check["kind"] != "command":
                        status, detail = coverage_check(check, worktree)
                        check_result = {
                            "id": check["id"],
                            "name": check["name"],
                            "status": status,
                            "detail": detail,
                        }
                        app_result["checks"].append(check_result)
                        print(f"CHECK_{status}: {app['id']}/{check['id']}", flush=True)
                        continue
                    repetitions = args.stress_repetitions if args.profile == "stress" and check.get("stressable") else 1
                    for repetition in range(1, repetitions + 1):
                        suffix = f"-repeat-{repetition}" if repetitions > 1 else ""
                        command = [substitute(item, variables) for item in check["command"]]
                        working_directory = worktree / check.get("working_directory", "")
                        environment = os.environ.copy()
                        environment["CI"] = "1"
                        environment["PATH"] = ":".join(
                            [
                                str(worktree / ".regression-venv" / "bin"),
                                str(Path.home() / ".local/bin"),
                                "/opt/homebrew/bin",
                                "/usr/local/bin",
                                environment.get("PATH", ""),
                            ]
                        )
                        regression_python = worktree / ".regression-venv" / "bin" / "python"
                        if regression_python.is_file():
                            environment.setdefault("HARNESS_RDFLIB_PYTHON", str(regression_python))
                        environment.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
                        for key, value in check.get("environment", {}).items():
                            environment[key] = substitute(value, variables)
                        log_path = app_artifacts / f"{check['id']}{suffix}.log"
                        code, timed_out, duration = run_process(
                            command,
                            cwd=working_directory,
                            environment=environment,
                            timeout_seconds=int(check.get("timeout_seconds", 900)),
                            log_path=log_path,
                        )
                        status = "PASS" if code == 0 and not timed_out else "FAIL"
                        name = check["name"] + (f" — repetition {repetition}/{repetitions}" if repetitions > 1 else "")
                        detail = "timed out" if timed_out else f"exit status {code}"
                        check_result = {
                            "id": check["id"] + suffix,
                            "name": name,
                            "status": status,
                            "detail": detail,
                            "duration_seconds": round(duration, 3),
                            "log": str(log_path),
                        }
                        app_result["checks"].append(check_result)
                        print(f"CHECK_{status}: {app['id']}/{check['id']}{suffix}", flush=True)
                check_statuses = {check["status"] for check in app_result["checks"]}
                app_result["status"] = "FAIL" if "FAIL" in check_statuses else "INCOMPLETE" if "GAP" in check_statuses else "PASS"
            except Exception as error:  # preserve evidence and continue the suite
                app_result["error"] = str(error)
                app_result["status"] = "FAIL"
                print(f"APP_FAIL: {app['id']}: {error}", flush=True)
            print(f"APP_END: {app['name']} {app_result['status']}", flush=True)
    finally:
        if not args.keep_worktrees:
            for app_id, worktree in prepared_worktrees.items():
                remove_worktree(app_id, args.cache_root, worktree)
        result["finished_at"] = utc_now()
        result["status"] = overall_status(result["apps"])
        json_path = report_dir / "result.json"
        json_path.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        markdown_path = report_dir / "report.md"
        markdown_path.write_text(markdown_report(result, report_dir), encoding="utf-8")
        latest_path = args.output_root / "latest.md"
        shutil.copyfile(markdown_path, latest_path)
        if args.notify:
            notify(result["status"], markdown_path)
        print(f"REGRESSION_STATUS: {result['status']}", flush=True)
        print(f"REGRESSION_REPORT: {markdown_path}", flush=True)
        print(f"REGRESSION_RESULT_JSON: {json_path}", flush=True)
    if result["status"] == "PASS":
        return 0
    return 2 if result["status"] == "INCOMPLETE" else 1


if __name__ == "__main__":
    raise SystemExit(main())
