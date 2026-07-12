#!/usr/bin/env python3
"""Run protected gate tests in a child process and require the full inventory."""

from __future__ import annotations

import argparse
import ast
import json
import os
import re
import signal
import subprocess
import sys
from pathlib import Path


def expected_tests(path: Path) -> set[str]:
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    return {
        node.name
        for parent in ast.walk(tree)
        if isinstance(parent, ast.ClassDef)
        for node in parent.body
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name.startswith("test_")
    }


def validate_transcript(transcript: str, expected: set[str], returncode: int) -> list[str]:
    errors: list[str] = []
    if returncode != 0:
        errors.append(f"protected gate tests exited {returncode}")
    match = re.search(r"Ran (\d+) tests? in", transcript)
    if not match or int(match.group(1)) != len(expected):
        errors.append("protected gate test inventory did not complete")
    if not re.search(r"(?m)^OK\s*$", transcript):
        errors.append("protected gate tests did not report OK")
    for name in sorted(expected):
        if not re.search(rf"(?m)^{re.escape(name)} \(.*\) \.\.\. ok$", transcript):
            errors.append(f"protected gate test result is missing: {name}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tests", type=Path, required=True)
    parser.add_argument("--proposal-scripts", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    expected = expected_tests(args.tests)
    env = dict(os.environ)
    env["HARNESS_SCRIPTS_UNDER_TEST"] = str(args.proposal_scripts.resolve())
    process = subprocess.Popen(
        [sys.executable, "-u", str(args.tests.resolve()), "-v"],
        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        env=env, cwd=args.proposal_scripts.resolve().parent, start_new_session=True,
    )
    transcript, _ = process.communicate()
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    errors = validate_transcript(transcript, expected, process.returncode)
    report = {
        "status": "PASS" if not errors else "FAIL",
        "expected_test_count": len(expected),
        "completed_test_count": len(expected) if not errors else 0,
        "errors": errors,
        "transcript": transcript,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1
    print(f"Protected gate test inventory completed: {len(expected)} tests.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
