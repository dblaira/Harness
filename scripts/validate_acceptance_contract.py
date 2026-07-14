#!/usr/bin/env python3
"""Fail closed when a pull request lacks a literal, testable acceptance contract."""

from __future__ import annotations

import argparse
import hashlib
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
    "Signed Mac UI automation",
    "Final accessibility identifier",
    "Required proof",
    "Risk and authority boundaries",
)
PLACEHOLDERS = ("REPLACE_WITH_", "TBD", "TODO")
HANDOFF_EXAMPLES = {
    "requirement_verbatim": "Paste Adam's exact requirement here.",
    "visible_surface": "Name the exact window, screen, or device.",
    "expected_visible_result": "State what must be visibly true at the end of the flow.",
    "ui_test_identifier": "HarnessUITests/ExactRequirementTests/testExactVisibleRequirement",
    "final_accessibility_identifier": "REPLACE_WITH_ACCESSIBILITY_IDENTIFIER",
}
COMMIT_BOUND_LIST_FIELDS = ("critical_flow", "required_proof")
COMMIT_BOUND_TEXT_FIELDS = ("risk_and_authority_boundaries", "threat_model")
CONTRACT_KEYS = frozenset({
    "requirement_verbatim",
    "visible_surface",
    "expected_visible_result",
    "ui_test_identifier",
    "ui_automation",
    "final_accessibility_identifier",
    *COMMIT_BOUND_LIST_FIELDS,
    *COMMIT_BOUND_TEXT_FIELDS,
})
REQUIREMENT_FRESHNESS_FIELDS = (
    "requirement_verbatim",
    "visible_surface",
    "expected_visible_result",
    "ui_test_identifier",
    "ui_automation",
    "final_accessibility_identifier",
)
UI_TEST_PATTERN = re.compile(r"^HarnessUITests/[A-Za-z_][A-Za-z0-9_]*/test[A-Za-z0-9_]+$")
ACCESSIBILITY_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ._:/-]{0,127}$")
UI_AUTOMATION_ACTIONS = frozenset({"wait_for", "press", "set_value", "assert_not_present"})
BOOTSTRAP_REPO = "dblaira/Harness"
BOOTSTRAP_PR = 19
BOOTSTRAP_BASE = "0ce97219a340d9a53f5afb2a773bb2c9eb81b807"


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
    signed_ui = section(body, "Signed Mac UI automation") or ""
    if signed_ui and not re.search(r"(?m)^\s*(?:[-*]|\d+[.)])\s+\S", signed_ui):
        errors.append("Signed Mac UI automation must contain committed ordered or bulleted actions")
    final_identifier = section(body, "Final accessibility identifier") or ""
    if final_identifier and not ACCESSIBILITY_PATTERN.fullmatch(final_identifier):
        errors.append("Final accessibility identifier must be one literal accessibility identifier")
    return errors


def bootstrap_allowed(repo: str | None, pr_number: int | None, base_sha: str | None) -> bool:
    return repo == BOOTSTRAP_REPO and pr_number == BOOTSTRAP_PR and base_sha == BOOTSTRAP_BASE


def contract_digest(contract: dict) -> str:
    canonical = json.dumps(contract, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def acceptance_fields(contract: dict) -> dict:
    return {key: contract.get(key) for key in sorted(CONTRACT_KEYS)}


def placeholder_present(value: str) -> bool:
    upper = value.upper()
    return "REPLACE_WITH_" in upper or bool(re.search(r"\b(?:TBD|TODO)\b", upper))


def nested_strings(value: object) -> list[str]:
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        return [text for item in value for text in nested_strings(item)]
    if isinstance(value, dict):
        return [text for item in value.values() for text in nested_strings(item)]
    return []


def freshness_errors(
    contract: dict,
    base_contract: dict | None,
    changed_paths: set[str],
    *,
    is_bootstrap: bool,
) -> list[str]:
    errors: list[str] = []
    if base_contract is None:
        if not is_bootstrap:
            errors.append("protected-base acceptance contract is required for freshness validation")
    elif all(base_contract.get(key) == contract.get(key) for key in REQUIREMENT_FRESHNESS_FIELDS):
        errors.append("acceptance contract is stale and unchanged from the protected base")
    if ".github/acceptance-contract.json" not in changed_paths and not is_bootstrap:
        errors.append("every guarded pull request must commit a fresh acceptance contract")
    return errors


def validate_handoff_contract(
    contract: dict,
    *,
    repo: str | None = None,
    pr_number: int | None = None,
    base_sha: str | None = None,
) -> list[str]:
    if not isinstance(contract, dict):
        return ["handoff contract must be a JSON object"]
    errors: list[str] = []
    unknown_keys = sorted(set(contract) - CONTRACT_KEYS)
    if unknown_keys:
        errors.append(f"unknown acceptance contract field(s): {', '.join(unknown_keys)}")
    for key, example in HANDOFF_EXAMPLES.items():
        value = contract.get(key)
        if not isinstance(value, str) or not value.strip():
            errors.append(f"{key} is required")
            continue
        if any(marker in value.upper() for marker in PLACEHOLDERS) or value.strip() == example:
            errors.append(f"placeholder remains in {key}")
    ui_test = contract.get("ui_test_identifier", "")
    if (
        isinstance(ui_test, str)
        and ui_test
        and ui_test != "INFRASTRUCTURE_ONLY"
        and not UI_TEST_PATTERN.fullmatch(ui_test)
    ):
        errors.append("ui_test_identifier must be INFRASTRUCTURE_ONLY or name one exact HarnessUITests test method")
    if ui_test == "INFRASTRUCTURE_ONLY" and not bootstrap_allowed(repo, pr_number, base_sha):
        errors.append("INFRASTRUCTURE_ONLY is restricted to the one reviewed bootstrap pull request")
    final_identifier = contract.get("final_accessibility_identifier", "")
    if not isinstance(final_identifier, str) or not ACCESSIBILITY_PATTERN.fullmatch(final_identifier):
        errors.append("final_accessibility_identifier must be one literal accessibility identifier")
    automation = contract.get("ui_automation")
    if not isinstance(automation, list) or not automation or len(automation) > 40:
        errors.append("ui_automation must contain 1 to 40 signed Mac actions")
    else:
        if not isinstance(automation[0], dict) or automation[0].get("action") != "wait_for":
            errors.append("ui_automation must begin with wait_for to bind the recorded candidate window")
        for index, step in enumerate(automation):
            prefix = f"ui_automation[{index}]"
            if not isinstance(step, dict):
                errors.append(f"{prefix} must be an action object")
                continue
            action = step.get("action")
            if action not in UI_AUTOMATION_ACTIONS:
                errors.append(f"{prefix}.action must be wait_for, press, set_value, or assert_not_present")
                continue
            allowed = {"action", "identifier", "timeout_seconds"}
            if action == "set_value":
                allowed.add("value")
            unknown = sorted(set(step) - allowed)
            if unknown:
                errors.append(f"{prefix} has unknown field(s): {', '.join(unknown)}")
            identifier = step.get("identifier")
            if not isinstance(identifier, str) or not ACCESSIBILITY_PATTERN.fullmatch(identifier):
                errors.append(f"{prefix}.identifier must be one literal accessibility identifier")
            timeout = step.get("timeout_seconds", 10)
            if not isinstance(timeout, int) or isinstance(timeout, bool) or not 1 <= timeout <= 60:
                errors.append(f"{prefix}.timeout_seconds must be an integer from 1 to 60")
            if action == "set_value":
                value = step.get("value")
                if not isinstance(value, str) or len(value) > 1000:
                    errors.append(f"{prefix}.value must be a string no longer than 1000 characters")
            elif "value" in step:
                errors.append(f"{prefix}.value is allowed only for set_value")
    for key in COMMIT_BOUND_LIST_FIELDS:
        value = contract.get(key)
        if not isinstance(value, list) or not value or not all(
            isinstance(item, str) and len(item.strip()) >= 12 for item in value
        ):
            errors.append(f"{key} must be a nonempty list of committed acceptance statements")
    for key in COMMIT_BOUND_TEXT_FIELDS:
        value = contract.get(key)
        if not isinstance(value, str) or len(value.strip()) < 20:
            errors.append(f"{key} must be committed in the acceptance contract")
    for text in nested_strings(contract):
        if placeholder_present(text):
            errors.append("placeholder remains in committed acceptance contract")
            break

    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    inputs = parser.add_mutually_exclusive_group(required=True)
    inputs.add_argument("--body-file", type=Path)
    inputs.add_argument("--contract-json", type=Path)
    parser.add_argument("--repo")
    parser.add_argument("--pr-number", type=int)
    parser.add_argument("--base-sha")
    parser.add_argument("--base-contract-json", type=Path)
    parser.add_argument("--changed-paths-file", type=Path)
    args = parser.parse_args()
    if args.body_file:
        errors = validate(args.body_file.read_text(encoding="utf-8"))
    else:
        try:
            contract = json.loads(args.contract_json.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            print(f"Invalid handoff contract: {error}", file=sys.stderr)
            return 1
        errors = validate_handoff_contract(
            contract,
            repo=args.repo,
            pr_number=args.pr_number,
            base_sha=args.base_sha,
        )
        is_bootstrap = bootstrap_allowed(args.repo, args.pr_number, args.base_sha)
        base_contract = None
        if args.base_contract_json:
            try:
                base_contract = json.loads(args.base_contract_json.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as error:
                errors.append(f"base acceptance contract is invalid: {error}")
        if args.changed_paths_file:
            changed_paths = {
                line.strip() for line in args.changed_paths_file.read_text(encoding="utf-8").splitlines() if line.strip()
            }
            errors.extend(freshness_errors(contract, base_contract, changed_paths, is_bootstrap=is_bootstrap))
    if errors:
        print("Acceptance contract failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    if args.contract_json:
        print(f"Commit-bound acceptance contract is complete: {contract_digest(contract)}")
    else:
        print("Pull-request display copy is complete.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
