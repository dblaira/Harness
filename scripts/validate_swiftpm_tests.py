#!/usr/bin/env python3
"""Validate SwiftPM Swift Testing output against a protected-base inventory."""
import argparse
import json
import re
import sys
from pathlib import Path

PASSED = re.compile(r"^✔ Test ([A-Za-z_][A-Za-z0-9_]*)\(\) passed ", re.MULTILINE)
SKIPPED = re.compile(r"^[↷⊘].*Test ([A-Za-z_][A-Za-z0-9_]*)\(\)", re.MULTILINE)

def leaf(identifier: str) -> str:
    return identifier.rsplit("/", 1)[-1].rsplit(".", 1)[-1].removesuffix("()")

def inventory(listing: str) -> list[str]:
    values = sorted(line.strip() for line in listing.splitlines() if line.strip())
    leaves = [leaf(value) for value in values]
    if not values or len(leaves) != len(set(leaves)):
        raise ValueError("protected SwiftPM inventory is empty or has ambiguous leaf identifiers")
    return values

def validate(expected: list[str], transcript: str, allowed_missing: set[str]) -> list[str]:
    passed = set(PASSED.findall(transcript))
    skipped = set(SKIPPED.findall(transcript))
    allowed_leaves = {leaf(item) for item in allowed_missing}
    required = {leaf(item) for item in expected if leaf(item) not in allowed_leaves}
    errors = []
    missing = sorted(required - passed)
    if missing: errors.append(f"SwiftPM omitted {len(missing)} protected test(s): {', '.join(missing)}")
    if skipped: errors.append(f"SwiftPM skipped {len(skipped)} unexpected test(s): {', '.join(sorted(skipped))}")
    return errors

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--listing", type=Path)
    parser.add_argument("--write-inventory", type=Path)
    parser.add_argument("--expected", type=Path)
    parser.add_argument("--transcript", type=Path)
    parser.add_argument("--allow-missing", action="append", default=[])
    args = parser.parse_args()
    try:
        if args.listing and args.write_inventory:
            values = inventory(args.listing.read_text(encoding="utf-8"))
            args.write_inventory.write_text(json.dumps(values, indent=2) + "\n", encoding="utf-8")
            print(f"Protected SwiftPM inventory contains {len(values)} tests.")
            return 0
        expected = json.loads(args.expected.read_text(encoding="utf-8"))
        errors = validate(expected, args.transcript.read_text(encoding="utf-8"), set(args.allow_missing))
    except Exception as error:
        print(f"invalid SwiftPM evidence: {error}", file=sys.stderr); return 1
    if errors:
        print("\n".join(errors), file=sys.stderr); return 1
    print("SwiftPM protected inventory passed without unexpected skips."); return 0
if __name__ == "__main__": raise SystemExit(main())
