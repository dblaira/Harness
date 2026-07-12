#!/usr/bin/env python3
"""Require one exact passing UI test and export its named window screenshot."""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Iterator


SCREENSHOT_NAME = "HARNESS_REQUIREMENT_VISIBLE_RESULT"


def objects(value: Any) -> Iterator[dict[str, Any]]:
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from objects(child)
    elif isinstance(value, list):
        for child in value:
            yield from objects(child)


def normalized_test_id(value: str) -> str:
    value = value.removeprefix("HarnessUITests/")
    return value[:-2] if value.endswith("()") else value


def validate_test_tree(
    tree: dict[str, Any],
    required_test: str,
    max_duration: float | None = None,
) -> list[str]:
    expected = normalized_test_id(required_test)
    matches = [
        node
        for node in objects(tree)
        if node.get("nodeType") == "Test Case"
        and normalized_test_id(str(node.get("nodeIdentifier", ""))) == expected
    ]
    if len(matches) != 1:
        return [f"expected exactly one executed UI test {required_test}; found {len(matches)}"]
    result = matches[0].get("result")
    if result != "Passed":
        return [f"required UI test result is {result!r}, not 'Passed'"]
    duration = float(matches[0].get("durationInSeconds", 0))
    if duration <= 0:
        return ["required UI test has no measured execution duration"]
    if max_duration is not None and duration > max_duration:
        return [f"required UI test exceeded the recorded evidence window: {duration:.2f}s"]
    return []


def validate_bundle_tree(
    tree: dict[str, Any],
    required_bundle: str,
    required_tests: set[str] | None = None,
) -> list[str]:
    bundles = [
        node for node in objects(tree)
        if node.get("name") == required_bundle
        and str(node.get("nodeType", "")).lower().endswith("test bundle")
    ]
    errors: list[str] = []
    if len(bundles) != 1 or bundles[0].get("result") != "Passed":
        errors.append(f"required test bundle {required_bundle} did not pass exactly once")
    cases = [node for node in objects(tree) if node.get("nodeType") == "Test Case"]
    if not cases:
        errors.append(f"required test bundle {required_bundle} executed no test cases")
    skipped = [node for node in cases if node.get("result") == "Skipped"]
    if skipped:
        errors.append(f"required test bundle {required_bundle} skipped {len(skipped)} test(s)")
    if required_tests is not None:
        executed = {normalized_test_id(str(node.get("nodeIdentifier", ""))).split("/")[-1] for node in cases}
        missing = sorted(required_tests - executed)
        if missing:
            errors.append(f"required test bundle omitted {len(missing)} protected test(s): {', '.join(missing)}")
    return errors


def run(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, text=True, capture_output=True, check=False)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--xcresult", required=True, type=Path)
    required = parser.add_mutually_exclusive_group(required=True)
    required.add_argument("--required-test")
    required.add_argument("--required-bundle")
    parser.add_argument("--screenshot-output", type=Path)
    parser.add_argument("--result-only", action="store_true")
    parser.add_argument("--max-duration", type=float)
    parser.add_argument("--required-test-list", type=Path)
    args = parser.parse_args()

    result = run(
        "xcrun", "xcresulttool", "get", "test-results", "tests",
        "--path", str(args.xcresult), "--compact",
    )
    if result.returncode:
        print(result.stderr, file=sys.stderr)
        return result.returncode
    try:
        tree = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        print(f"Invalid xcresult test tree: {error}", file=sys.stderr)
        return 1
    required_tests = None
    if args.required_test_list:
        try:
            inventory = json.loads(args.required_test_list.read_text(encoding="utf-8"))
            if not isinstance(inventory, list) or not inventory or not all(isinstance(item, str) for item in inventory):
                raise ValueError("inventory must be a nonempty string list")
            required_tests = set(inventory)
        except (OSError, json.JSONDecodeError, ValueError) as error:
            print(f"Invalid protected test inventory: {error}", file=sys.stderr)
            return 1
    if args.required_bundle and required_tests is None:
        print("--required-test-list is mandatory with --required-bundle", file=sys.stderr)
        return 2
    errors = (
        validate_test_tree(tree, args.required_test, args.max_duration)
        if args.required_test
        else validate_bundle_tree(tree, args.required_bundle, required_tests)
    )
    if errors:
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    if args.required_bundle:
        print(f"Test bundle passed with no skipped tests: {args.required_bundle}")
        return 0
    if args.result_only:
        print(f"Exact UI test passed: {args.required_test}")
        return 0
    if args.screenshot_output is None:
        print("--screenshot-output is required with --required-test", file=sys.stderr)
        return 2

    executed_id = next(
        str(node["nodeIdentifier"])
        for node in objects(tree)
        if node.get("nodeType") == "Test Case"
        and normalized_test_id(str(node.get("nodeIdentifier", ""))) == normalized_test_id(args.required_test)
    )
    with tempfile.TemporaryDirectory(prefix="harness-xcresult-") as directory:
        export_dir = Path(directory)
        export = run(
            "xcrun", "xcresulttool", "export", "attachments",
            "--path", str(args.xcresult), "--output-path", str(export_dir),
            "--test-id", executed_id,
        )
        if export.returncode:
            print(export.stderr or export.stdout, file=sys.stderr)
            return export.returncode
        manifest = json.loads((export_dir / "manifest.json").read_text(encoding="utf-8"))
        candidates = []
        for test in manifest:
            if normalized_test_id(str(test.get("testIdentifier", ""))) != normalized_test_id(args.required_test):
                continue
            for attachment in test.get("attachments", []):
                suggested = str(attachment.get("suggestedHumanReadableName", ""))
                exported = str(attachment.get("exportedFileName", ""))
                if suggested.startswith(SCREENSHOT_NAME) and exported.lower().endswith(".png"):
                    candidates.append(export_dir / exported)
        if len(candidates) != 1 or not candidates[0].is_file() or candidates[0].stat().st_size == 0:
            print(f"Required UI test must attach exactly one nonempty {SCREENSHOT_NAME} PNG.", file=sys.stderr)
            return 1
        args.screenshot_output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(candidates[0], args.screenshot_output)
    print(f"Exact UI test passed and exported its window evidence: {args.required_test}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
