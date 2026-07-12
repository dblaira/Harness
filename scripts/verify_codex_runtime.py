#!/usr/bin/env python3
"""Attest the effective Codex model, provider, sandbox, and reasoning settings."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


EXPECTED = {
    "model": "gpt-5.6-sol",
    "provider": "openai",
    "sandbox": "read-only",
    "reasoning effort": "max",
}


def header_values(log: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for key in EXPECTED:
        match = re.search(rf"(?m)^{re.escape(key)}:\s*(.+?)\s*$", log)
        if match:
            values[key] = match.group(1)
    return values


def validate(log: str) -> tuple[list[str], dict[str, str]]:
    values = header_values(log)
    errors = []
    for key, expected in EXPECTED.items():
        actual = values.get(key)
        if actual != expected:
            errors.append(f"effective Codex {key} is {actual or 'missing'}, expected {expected}")
    return errors, values


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    log = args.log.read_text(encoding="utf-8", errors="replace")
    errors, values = validate(log)
    proof = {"status": "PASS" if not errors else "FAIL", **values, "errors": errors}
    args.output.write_text(json.dumps(proof, indent=2) + "\n", encoding="utf-8")
    if errors:
        for error in errors:
            print(error)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
