#!/usr/bin/env python3
"""Fail closed when a pull request lacks a literal, testable acceptance contract."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


REQUIRED_SECTIONS = (
    "Requirement verbatim",
    "Visible surface",
    "Expected visible result",
    "Critical flow",
    "Exact UI test",
    "Required proof",
    "Risk and authority boundaries",
)
PLACEHOLDERS = ("REPLACE_WITH_", "TBD", "TODO")
HANDOFF_EXAMPLES = {
    "requirement_verbatim": "Paste Adam's exact requirement here.",
    "visible_surface": "Name the exact window, screen, or device.",
    "expected_visible_result": "State what must be visibly true at the end of the flow.",
    "ui_test_identifier": "HarnessUITests/ExactRequirementTests/testExactVisibleRequirement",
}
UI_TEST_PATTERN = re.compile(r"^HarnessUITests/[A-Za-z_][A-Za-z0-9_]*/test[A-Za-z0-9_]+$")


def section(body: str, name: str) -> str | None:
    match = re.search(
        rf"(?ms)^##\s+{re.escape(name)}\s*$\n(.*?)(?=^##\s+|\Z)", body
    )
    return match.group(1).strip() if match else None


def validate(body: str) -> list[str]:
    errors: list[str] = []
    for name in REQUIRED_SECTIONS:
        content = section(body, name)
        if content is None:
            errors.append(f"missing section: {name}")
            continue
        if not content:
            errors.append(f"empty section: {name}")
            continue
        if any(marker in content.upper() for marker in PLACEHOLDERS):
            errors.append(f"placeholder remains in section: {name}")

    critical_flow = section(body, "Critical flow") or ""
    if critical_flow and not re.search(r"(?m)^\s*(?:[-*]|\d+[.)])\s+\S", critical_flow):
        errors.append("Critical flow must contain executable ordered or bulleted steps")

    proof = section(body, "Required proof") or ""
    if proof and not re.search(r"(?i)\b(test|screenshot|video|recording|infrastructure)\b", proof):
        errors.append("Required proof must name tests and visible evidence, or say infrastructure-only")
    exact_ui_test = section(body, "Exact UI test") or ""
    if exact_ui_test and exact_ui_test != "INFRASTRUCTURE_ONLY" and not UI_TEST_PATTERN.fullmatch(exact_ui_test):
        errors.append("Exact UI test must be INFRASTRUCTURE_ONLY or one HarnessUITests test identifier")
    return errors


def validate_handoff_contract(contract: dict, pr_body: str | None = None) -> list[str]:
    if not isinstance(contract, dict):
        return ["handoff contract must be a JSON object"]
    errors: list[str] = []
    for key, example in HANDOFF_EXAMPLES.items():
        value = contract.get(key)
        if not isinstance(value, str) or not value.strip():
            errors.append(f"{key} is required")
            continue
        if any(marker in value.upper() for marker in PLACEHOLDERS) or value.strip() == example:
            errors.append(f"placeholder remains in {key}")
    ui_test = contract.get("ui_test_identifier", "")
    if isinstance(ui_test, str) and ui_test and not UI_TEST_PATTERN.fullmatch(ui_test):
        errors.append("ui_test_identifier must name one exact HarnessUITests test method")

    if pr_body is not None:
        mapping = {
            "requirement_verbatim": "Requirement verbatim",
            "visible_surface": "Visible surface",
            "expected_visible_result": "Expected visible result",
            "ui_test_identifier": "Exact UI test",
        }
        markdown_errors = validate(pr_body)
        errors.extend(f"reviewed PR: {error}" for error in markdown_errors)
        for key, heading in mapping.items():
            if section(pr_body, heading) != contract.get(key):
                errors.append(f"{key} does not exactly match the reviewed pull request")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    inputs = parser.add_mutually_exclusive_group(required=True)
    inputs.add_argument("--body-file", type=Path)
    inputs.add_argument("--contract-json", type=Path)
    parser.add_argument("--pr-body-file", type=Path)
    args = parser.parse_args()
    if args.body_file:
        errors = validate(args.body_file.read_text(encoding="utf-8"))
    else:
        try:
            contract = json.loads(args.contract_json.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            print(f"Invalid handoff contract: {error}", file=sys.stderr)
            return 1
        pr_body = args.pr_body_file.read_text(encoding="utf-8") if args.pr_body_file else None
        errors = validate_handoff_contract(contract, pr_body)
    if errors:
        print("Acceptance contract failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print("Acceptance contract is complete and bound to its reviewed text.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
