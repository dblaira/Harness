from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

import release_gate  # noqa: E402
import validate_acceptance_contract  # noqa: E402
import validate_sol_review  # noqa: E402


class AcceptanceContractTests(unittest.TestCase):
    def test_placeholders_fail_closed(self) -> None:
        body = "\n".join(f"## {name}\n\nREPLACE_WITH_VALUE" for name in validate_acceptance_contract.REQUIRED_SECTIONS)
        self.assertTrue(validate_acceptance_contract.validate(body))

    def test_complete_contract_passes(self) -> None:
        body = """## Requirement verbatim
The visible answer must appear in the same window.
## Visible surface
Harness answer window on Adam's Mac.
## Expected visible result
The answer is visible and no progress state remains.
## Critical flow
1. Open Harness.
2. Submit the request and observe the answer.
## Required proof
- Unit and UI tests, screenshot, and video.
## Risk and authority boundaries
Signed app, provider authentication, and accepted graph remain distinct.
"""
        self.assertEqual(validate_acceptance_contract.validate(body), [])


class SolReviewTests(unittest.TestCase):
    def test_blocking_finding_fails(self) -> None:
        sha_a, sha_b = "a" * 40, "b" * 40
        review = {
            "reviewed_base": sha_a,
            "reviewed_head": sha_b,
            "verdict": "PASS",
            "acceptance_contract_complete": True,
            "read_only_review": True,
            "findings": [{"severity": "P1"}],
        }
        self.assertTrue(validate_sol_review.validate(review, sha_a, sha_b))


class ReleaseGateTests(unittest.TestCase):
    def test_completion_language(self) -> None:
        self.assertTrue(release_gate.completion_claim("Implemented and verified."))
        self.assertFalse(release_gate.completion_claim("Blocked; this is not verified."))

    def test_hook_allows_only_explicit_blocked_exit_without_evidence(self) -> None:
        original = release_gate.product_changes
        release_gate.product_changes = lambda _root: ["Sources/Harness/Feature.swift"]
        try:
            result = release_gate.hook(Path("."), {"last_assistant_message": "BLOCKED: missing external authority"})
            self.assertEqual(result, {"continue": True})
        finally:
            release_gate.product_changes = original

    def test_missing_artifacts_fail_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest_path = root / "manifest.json"
            manifest_path.write_text(json.dumps({"schema_version": 1, "status": "PASS"}), encoding="utf-8")
            errors = release_gate.validate_manifest(root, manifest_path)
            self.assertIn("manifest commit does not match HEAD", errors)
            self.assertIn("artifact is missing: screenshot", errors)


if __name__ == "__main__":
    unittest.main()
