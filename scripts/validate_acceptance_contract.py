#!/usr/bin/env python3
"""Fail closed when a pull request lacks a literal, testable acceptance contract."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


REQUIRED_SECTIONS = (
    "Requirement verbatim",
    "Visible surface",
    "Expected visible result",
    "Critical flow",
    "Required proof",
    "Risk and authority boundaries",
)
PLACEHOLDERS = ("REPLACE_WITH_", "TBD", "TODO")


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
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--body-file", required=True, type=Path)
    args = parser.parse_args()
    body = args.body_file.read_text(encoding="utf-8")
    errors = validate(body)
    if errors:
        print("Acceptance contract failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print("Acceptance contract is complete.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
