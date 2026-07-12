from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

import release_gate  # noqa: E402
import require_latest_status  # noqa: E402
import validate_acceptance_contract  # noqa: E402
import validate_sol_review  # noqa: E402
import validate_xcresult  # noqa: E402
import verify_release_tree  # noqa: E402


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
## Exact UI test
HarnessUITests/AnswerTests/testVisibleAnswer
## Required proof
- Unit and UI tests, screenshot, and video.
## Risk and authority boundaries
Signed app, provider authentication, and accepted graph remain distinct.
"""
        self.assertEqual(validate_acceptance_contract.validate(body), [])

    def test_handoff_examples_and_non_ui_test_fail(self) -> None:
        contract = dict(validate_acceptance_contract.HANDOFF_EXAMPLES)
        contract["ui_test_identifier"] = "HarnessTests/FeatureTests/testFeature"
        errors = validate_acceptance_contract.validate_handoff_contract(contract)
        self.assertIn("placeholder remains in requirement_verbatim", errors)
        self.assertIn(
            "ui_test_identifier must be INFRASTRUCTURE_ONLY or name one exact HarnessUITests test method",
            errors,
        )

    def test_handoff_contract_must_match_reviewed_pr(self) -> None:
        contract = {
            "requirement_verbatim": "Exact requirement",
            "visible_surface": "Harness window",
            "expected_visible_result": "The answer is visible",
            "ui_test_identifier": "HarnessUITests/AnswerTests/testVisibleAnswer",
        }
        body = """## Requirement verbatim
Different requirement
## Visible surface
Harness window
## Expected visible result
The answer is visible
## Critical flow
1. Run the flow.
## Exact UI test
HarnessUITests/AnswerTests/testVisibleAnswer
## Required proof
- UI test and screenshot.
## Risk and authority boundaries
Signing remains separate.
"""
        self.assertIn(
            "requirement_verbatim does not exactly match the reviewed pull request",
            validate_acceptance_contract.validate_handoff_contract(contract, body),
        )

    def test_infrastructure_only_contract_is_consistent(self) -> None:
        contract = {
            "requirement_verbatim": "Install protected verification infrastructure.",
            "visible_surface": "GitHub pull request checks.",
            "expected_visible_result": "Every required gate is visible.",
            "ui_test_identifier": "INFRASTRUCTURE_ONLY",
        }
        body = """## Requirement verbatim
Install protected verification infrastructure.
## Visible surface
GitHub pull request checks.
## Expected visible result
Every required gate is visible.
## Critical flow
1. Open the pull request checks.
## Exact UI test
INFRASTRUCTURE_ONLY
## Required proof
- Infrastructure checks and signed-app smoke test.
## Risk and authority boundaries
No product feature is accepted through this path.
"""
        self.assertEqual(
            validate_acceptance_contract.validate_handoff_contract(contract, body),
            [],
        )


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

    def test_hook_allows_intermediate_non_completion_message(self) -> None:
        original = release_gate.product_changes
        release_gate.product_changes = lambda _root: ["Sources/Harness/Feature.swift"]
        try:
            result = release_gate.hook(Path("."), {"last_assistant_message": "I need Adam to choose A or B."})
            self.assertEqual(result, {"continue": True})
        finally:
            release_gate.product_changes = original

    def test_git_inspection_failure_blocks_completion(self) -> None:
        original = release_gate.product_changes
        release_gate.product_changes = lambda _root: (_ for _ in ()).throw(
            release_gate.GitInspectionError("git status failed: repository unreadable")
        )
        try:
            result = release_gate.hook(Path("."), {"last_assistant_message": "Implemented and verified."})
            self.assertEqual(result["decision"], "block")
            self.assertIn("repository unreadable", result["reason"])
        finally:
            release_gate.product_changes = original

    def test_package_manifests_are_product_changes(self) -> None:
        original = release_gate.changed_files
        release_gate.changed_files = lambda _root: {
            "Packages/OntologyKit/Package.swift",
            "Packages/OntologyKit/Package.resolved",
        }
        try:
            self.assertEqual(
                release_gate.product_changes(Path(".")),
                [
                    "Packages/OntologyKit/Package.resolved",
                    "Packages/OntologyKit/Package.swift",
                ],
            )
        finally:
            release_gate.changed_files = original

    def test_missing_artifacts_fail_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path.cwd()
            manifest_path = Path(directory) / "manifest.json"
            manifest_path.write_text(json.dumps({"schema_version": 1, "status": "PASS"}), encoding="utf-8")
            errors = release_gate.validate_manifest(root, manifest_path)
            self.assertIn("manifest commit does not match HEAD", errors)
            self.assertIn("artifact is missing: screenshot", errors)


class XCResultGateTests(unittest.TestCase):
    def test_exact_passing_ui_test_is_required(self) -> None:
        tree = {
            "testNodes": [{
                "nodeType": "Test Case",
                "nodeIdentifier": "VisibleAnswerTests/testVisibleAnswer()",
                "result": "Passed",
                "durationInSeconds": 1.25,
            }]
        }
        self.assertEqual(
            validate_xcresult.validate_test_tree(
                tree, "HarnessUITests/VisibleAnswerTests/testVisibleAnswer"
            ),
            [],
        )
        self.assertTrue(
            validate_xcresult.validate_test_tree(
                tree, "HarnessUITests/VisibleAnswerTests/testDifferentAnswer"
            )
        )

    def test_unit_bundle_rejects_skips(self) -> None:
        tree = {"children": [
            {"name": "HarnessTests", "nodeType": "Unit test bundle", "result": "Passed"},
            {"name": "testOne()", "nodeType": "Test Case", "result": "Skipped"},
        ]}
        self.assertIn(
            "required test bundle HarnessTests skipped 1 test(s)",
            validate_xcresult.validate_bundle_tree(tree, "HarnessTests"),
        )


class CommitStatusTests(unittest.TestCase):
    def test_newest_failure_rejects_older_success(self) -> None:
        payload = {"statuses": [
            {"context": "GPT-5.6 Sol review", "state": "failure", "target_url": "new"},
            {"context": "GPT-5.6 Sol review", "state": "success", "target_url": "old"},
        ]}
        errors, _ = require_latest_status.require_latest(payload, "GPT-5.6 Sol review")
        self.assertEqual(errors, ["newest GPT-5.6 Sol review status is failure"])


class ReleaseTreeTests(unittest.TestCase):
    def test_merge_commit_attests_exact_verified_tree_and_checks(self) -> None:
        merge, first, head, tree = "m" * 40, "a" * 40, "b" * 40, "t" * 40
        status_contexts = {"Acceptance contract", "GPT-5.6 Sol review", "Signed Mac handoff"}
        statuses = {"statuses": [
            {"context": context, "state": "success", "target_url": f"https://example/{context}"}
            for context in status_contexts
        ]}
        checks = {"check_runs": [
            {"name": context, "status": "completed", "conclusion": "success", "html_url": f"https://example/{context}"}
            for context in verify_release_tree.REQUIRED_CONTEXTS
            if context not in status_contexts
        ]}
        errors, attestation = verify_release_tree.validate(
            merge,
            f"{merge} {first} {head}",
            tree,
            tree,
            statuses,
            checks,
        )
        self.assertEqual(errors, [])
        self.assertEqual(attestation["verified_head"], head)

    def test_release_tree_rejects_a_different_main_tree(self) -> None:
        errors, _ = verify_release_tree.validate(
            "m" * 40,
            f"{'m' * 40} {'a' * 40} {'b' * 40}",
            "x" * 40,
            "y" * 40,
            {"statuses": []},
            {"check_runs": []},
        )
        self.assertIn(
            "main merge tree does not exactly match the verified pull-request head tree",
            errors,
        )


if __name__ == "__main__":
    unittest.main()
