#!/usr/bin/env python3
"""Verify the candidate Harness bundle before its first launch."""

from __future__ import annotations

import argparse
import json
import plistlib
import re
import subprocess
from pathlib import Path
from typing import Any


EXPECTED_BUNDLE_ID = "com.adamblair.Harness"
EXPECTED_TEAM = "7FKUS5M5QS"
REQUIRED_ENTITLEMENTS: dict[str, Any] = {
    "com.apple.application-identifier": f"{EXPECTED_TEAM}.{EXPECTED_BUNDLE_ID}",
    "com.apple.developer.team-identifier": EXPECTED_TEAM,
    "com.apple.developer.icloud-container-identifiers": ["iCloud.com.adamblair.harness"],
    "com.apple.developer.ubiquity-container-identifiers": ["iCloud.com.adamblair.harness"],
    "com.apple.security.app-sandbox": False,
    "com.apple.security.device.audio-input": True,
    "com.apple.security.network.client": True,
}


def run(*args: str) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(args, capture_output=True, check=False)


def signature_value(signature: str, name: str) -> str | None:
    match = re.search(rf"(?m)^{re.escape(name)}=(.+)$", signature)
    return match.group(1).strip() if match else None


def validate_identity(
    bundle_id: str,
    signature: str,
    designated_requirement: str,
    entitlements: dict[str, Any],
) -> tuple[list[str], dict[str, Any]]:
    team = signature_value(signature, "TeamIdentifier")
    cdhash = signature_value(signature, "CDHash")
    errors: list[str] = []
    if bundle_id != EXPECTED_BUNDLE_ID:
        errors.append(f"bundle identifier is {bundle_id or 'missing'}, expected {EXPECTED_BUNDLE_ID}")
    if team != EXPECTED_TEAM:
        errors.append(f"signing team is {team or 'missing'}, expected {EXPECTED_TEAM}")
    if not cdhash:
        errors.append("signed app has no CDHash")
    requirement_marker = f'identifier "{EXPECTED_BUNDLE_ID}" and anchor apple generic'
    if requirement_marker not in designated_requirement:
        errors.append("designated requirement does not bind the Harness identifier to Apple signing")
    for key, expected in REQUIRED_ENTITLEMENTS.items():
        if entitlements.get(key) != expected:
            errors.append(f"entitlement {key} does not match the required value")
    return errors, {
        "bundle_identifier": bundle_id,
        "team_identifier": team,
        "cdhash": cdhash,
        "designated_requirement": designated_requirement.strip(),
        "entitlements": entitlements,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    info_path = args.app / "Contents" / "Info.plist"
    if not info_path.is_file():
        parser.error(f"candidate Info.plist is missing: {info_path}")

    verify = run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(args.app))
    signature = run("/usr/bin/codesign", "-dvvv", str(args.app))
    requirement = run("/usr/bin/codesign", "-dr", "-", str(args.app))
    entitlement_result = run("/usr/bin/codesign", "-d", "--entitlements", ":-", str(args.app))
    errors = []
    if verify.returncode:
        errors.append("candidate does not pass deep strict codesign verification")
    try:
        bundle_id = plistlib.loads(info_path.read_bytes()).get("CFBundleIdentifier", "")
    except (OSError, plistlib.InvalidFileException) as error:
        bundle_id = ""
        errors.append(f"cannot read candidate Info.plist: {error}")
    try:
        entitlements = plistlib.loads(entitlement_result.stdout)
    except plistlib.InvalidFileException:
        entitlements = {}
        errors.append("cannot decode candidate signed entitlements")
    signature_text = (signature.stderr + signature.stdout).decode("utf-8", errors="replace")
    requirement_text = (requirement.stderr + requirement.stdout).decode("utf-8", errors="replace")
    identity_errors, proof = validate_identity(
        str(bundle_id), signature_text, requirement_text, entitlements
    )
    errors.extend(identity_errors)
    proof.update({"status": "PASS" if not errors else "FAIL", "errors": errors})
    args.output.write_text(json.dumps(proof, indent=2) + "\n", encoding="utf-8")
    if errors:
        for error in errors:
            print(error)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
