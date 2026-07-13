from __future__ import annotations

import copy
import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPTS = Path(os.environ.get("HARNESS_SCRIPTS_UNDER_TEST", Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(SCRIPTS))

import release_gate  # noqa: E402
import live_satisfaction_oracle  # noqa: E402
import evidence_binding  # noqa: E402
import periphery_changed_gate  # noqa: E402
import resolve_harness_repo  # noqa: E402
import route_stop_gate  # noqa: E402
import run_gate_script_tests  # noqa: E402
import sanitize_review_bundle  # noqa: E402
import swift_test_inventory  # noqa: E402
import select_pull_request  # noqa: E402
import require_latest_status  # noqa: E402
import validate_acceptance_contract  # noqa: E402
import validate_media  # noqa: E402
import validate_gate_test_report  # noqa: E402
import validate_sol_review  # noqa: E402
import validate_xcresult  # noqa: E402
import validate_swiftpm_tests  # noqa: E402
import verify_release_tree  # noqa: E402
import verify_codex_auth  # noqa: E402
import verify_codex_runtime  # noqa: E402
import verify_app_identity  # noqa: E402
import verify_control_bundle  # noqa: E402
import verify_hosted_evidence  # noqa: E402
import verify_merge_authority  # noqa: E402
import verify_repository_gate_state  # noqa: E402


COMMIT_BOUND_FIXTURE = {
    "critical_flow": ["Run the exact flow."],
    "required_proof": ["Capture tests and visible evidence."],
    "risk_and_authority_boundaries": "Signing and accepted authority remain distinct.",
    "threat_model": "The authenticated operator is trusted.",
}


class AcceptanceContractTests(unittest.TestCase):
    def test_documented_product_contract_example_is_schema_valid(self) -> None:
        example = json.loads((Path.cwd() / "Docs/verification/acceptance-contract.example.json").read_text())
        self.assertEqual(validate_acceptance_contract.validate_handoff_contract(example), [])
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
## Final accessibility identifier
VisibleAnswer
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

    def test_infrastructure_only_contract_is_consistent(self) -> None:
        contract = {
            **COMMIT_BOUND_FIXTURE,
            "requirement_verbatim": "Install protected verification infrastructure.",
            "visible_surface": "GitHub pull request checks.",
            "expected_visible_result": "Every required gate is visible.",
            "ui_test_identifier": "INFRASTRUCTURE_ONLY",
            "final_accessibility_identifier": "Delegation",
        }
        self.assertEqual(
            validate_acceptance_contract.validate_handoff_contract(
                contract,
                repo=validate_acceptance_contract.BOOTSTRAP_REPO,
                pr_number=validate_acceptance_contract.BOOTSTRAP_PR,
                base_sha=validate_acceptance_contract.BOOTSTRAP_BASE,
            ),
            [],
        )

    def test_infrastructure_only_is_rejected_outside_bootstrap(self) -> None:
        contract = {
            **COMMIT_BOUND_FIXTURE,
            "requirement_verbatim": "Change a product feature.",
            "visible_surface": "Harness window",
            "expected_visible_result": "Feature appears",
            "ui_test_identifier": "INFRASTRUCTURE_ONLY",
            "final_accessibility_identifier": "Feature",
        }
        errors = validate_acceptance_contract.validate_handoff_contract(
            contract,
            repo="dblaira/Harness",
            pr_number=20,
            base_sha="a" * 40,
        )
        self.assertIn(
            "INFRASTRUCTURE_ONLY is restricted to the one reviewed bootstrap pull request",
            errors,
        )

    def test_unchanged_prior_contract_is_rejected(self) -> None:
        contract = {
            **COMMIT_BOUND_FIXTURE,
            "requirement_verbatim": "Exact requirement",
            "visible_surface": "Harness window",
            "expected_visible_result": "Exact visible result",
            "ui_test_identifier": "HarnessUITests/AnswerTests/testVisibleAnswer",
            "final_accessibility_identifier": "VisibleAnswer",
        }
        errors = validate_acceptance_contract.freshness_errors(
            contract,
            dict(contract),
            {".github/acceptance-contract.json", "Sources/Harness/Feature.swift"},
            is_bootstrap=False,
        )
        self.assertIn("acceptance contract is stale and unchanged from the protected base", errors)

    def test_nonce_only_contract_change_is_unknown_and_stale(self) -> None:
        base = {
            **COMMIT_BOUND_FIXTURE,
            "requirement_verbatim": "Exact requirement",
            "visible_surface": "Harness window",
            "expected_visible_result": "Exact visible result",
            "ui_test_identifier": "HarnessUITests/AnswerTests/testVisibleAnswer",
            "final_accessibility_identifier": "VisibleAnswer",
        }
        proposed = {**base, "nonce": "changed"}
        self.assertIn(
            "unknown acceptance contract field(s): nonce",
            validate_acceptance_contract.validate_handoff_contract(proposed),
        )
        self.assertIn(
            "acceptance contract is stale and unchanged from the protected base",
            validate_acceptance_contract.freshness_errors(
                proposed,
                base,
                {".github/acceptance-contract.json"},
                is_bootstrap=False,
            ),
        )

    def test_literal_requirement_change_is_fresh(self) -> None:
        base = {
            **COMMIT_BOUND_FIXTURE,
            "requirement_verbatim": "Old literal requirement",
            "visible_surface": "Harness window",
            "expected_visible_result": "Old visible result",
            "ui_test_identifier": "HarnessUITests/AnswerTests/testVisibleAnswer",
            "final_accessibility_identifier": "VisibleAnswer",
        }
        proposed = {**base, "requirement_verbatim": "New literal requirement"}
        self.assertEqual(
            validate_acceptance_contract.freshness_errors(
                proposed,
                base,
                {".github/acceptance-contract.json"},
                is_bootstrap=False,
            ),
            [],
        )

    def test_governance_or_proof_only_change_remains_stale(self) -> None:
        base = {
            **COMMIT_BOUND_FIXTURE,
            "requirement_verbatim": "Exact requirement",
            "visible_surface": "Harness window",
            "expected_visible_result": "Exact result",
            "ui_test_identifier": "HarnessUITests/AnswerTests/testVisibleAnswer",
            "final_accessibility_identifier": "VisibleAnswer",
        }
        for field, value in (
            ("risk_and_authority_boundaries", "Different but sufficiently long risk prose."),
            ("threat_model", "Different but sufficiently long threat prose."),
            ("required_proof", ["Different screenshot and test proof."]),
            ("critical_flow", ["Different execution flow statement."]),
        ):
            proposed = {**base, field: value}
            self.assertIn(
                "acceptance contract is stale and unchanged from the protected base",
                validate_acceptance_contract.freshness_errors(
                    proposed, base, {".github/acceptance-contract.json"}, is_bootstrap=False
                ),
            )

    def test_placeholders_in_every_commit_bound_field_are_rejected(self) -> None:
        for field, value in (
            ("critical_flow", ["TODO replace this critical flow"]),
            ("required_proof", ["TBD screenshot and test proof"]),
            ("risk_and_authority_boundaries", "TODO explain the authority boundary"),
            ("threat_model", "TBD explain the complete threat model"),
        ):
            contract = {
                **COMMIT_BOUND_FIXTURE,
                "requirement_verbatim": "Exact requirement",
                "visible_surface": "Harness window",
                "expected_visible_result": "Exact visible result",
                "ui_test_identifier": "HarnessUITests/AnswerTests/testVisibleAnswer",
                "final_accessibility_identifier": "VisibleAnswer",
                field: value,
            }
            self.assertIn(
                "placeholder remains in committed acceptance contract",
                validate_acceptance_contract.validate_handoff_contract(contract),
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
        original = release_gate.guarded_changes
        release_gate.guarded_changes = lambda _root: ["Sources/Harness/Feature.swift"]
        try:
            result = release_gate.hook(Path("."), {"last_assistant_message": "BLOCKED: missing external authority"})
            self.assertEqual(result, {"continue": True})
        finally:
            release_gate.guarded_changes = original

    def test_hook_rejects_blocked_message_with_mixed_completion_claims(self) -> None:
        original = release_gate.guarded_changes
        release_gate.guarded_changes = lambda _root: ["Sources/Harness/Feature.swift"]
        try:
            for message in (
                "BLOCKED: implemented and verified; handoff evidence is absent",
                "BLOCKED: tests pass but the manifest is missing",
                "BLOCKED: the feature is working; release proof is unavailable",
            ):
                result = release_gate.hook(Path("."), {"last_assistant_message": message})
                self.assertEqual(result["decision"], "block")
            self.assertEqual(
                release_gate.hook(
                    Path("."),
                    {"last_assistant_message": "BLOCKED: not verified because signing authority is absent"},
                ),
                {"continue": True},
            )
        finally:
            release_gate.guarded_changes = original

    def test_hook_allows_intermediate_non_completion_message(self) -> None:
        original = release_gate.guarded_changes
        release_gate.guarded_changes = lambda _root: ["Sources/Harness/Feature.swift"]
        try:
            result = release_gate.hook(Path("."), {"last_assistant_message": "Adam, should I use A or B?"})
            self.assertEqual(result, {"continue": True})
        finally:
            release_gate.guarded_changes = original

    def test_question_shaped_completion_claims_are_blocked(self) -> None:
        original = release_gate.guarded_changes
        release_gate.guarded_changes = lambda _root: ["Sources/Harness/Feature.swift"]
        try:
            for message in (
                "Everything passes; does that look right?",
                "The issue now works; anything else?",
                "The repair was successful; should I stop?",
            ):
                result = release_gate.hook(Path("."), {"last_assistant_message": message})
                self.assertEqual(result["decision"], "block")
        finally:
            release_gate.guarded_changes = original

    def test_genuine_information_question_is_allowed(self) -> None:
        original = release_gate.guarded_changes
        release_gate.guarded_changes = lambda _root: ["Sources/Harness/Feature.swift"]
        try:
            result = release_gate.hook(
                Path("."), {"last_assistant_message": "Adam, should I use the signed Debug or Release identity?"}
            )
            self.assertEqual(result, {"continue": True})
        finally:
            release_gate.guarded_changes = original

    def test_hook_blocks_malformed_paraphrased_and_mixed_completion(self) -> None:
        original = release_gate.guarded_changes
        release_gate.guarded_changes = lambda _root: ["Sources/Harness/Feature.swift"]
        try:
            messages = (
                "",
                "The requirement now passes.",
                "Implemented successfully, though an unrelated note is unverified.",
            )
            for message in messages:
                result = release_gate.hook(Path("."), {"last_assistant_message": message})
                self.assertEqual(result["decision"], "block")
        finally:
            release_gate.guarded_changes = original

    def test_missing_base_fails_closed(self) -> None:
        original = release_gate.run_git
        release_gate.run_git = lambda _root, *args: (_ for _ in ()).throw(
            release_gate.GitInspectionError(f"git {' '.join(args)} failed: missing base")
        )
        try:
            with self.assertRaises(release_gate.GitInspectionError):
                release_gate.changed_files(Path("."))
        finally:
            release_gate.run_git = original

    def test_git_inspection_failure_blocks_completion(self) -> None:
        original = release_gate.guarded_changes
        release_gate.guarded_changes = lambda _root: (_ for _ in ()).throw(
            release_gate.GitInspectionError("git status failed: repository unreadable")
        )
        try:
            result = release_gate.hook(Path("."), {"last_assistant_message": "Implemented and verified."})
            self.assertEqual(result["decision"], "block")
            self.assertIn("repository unreadable", result["reason"])
        finally:
            release_gate.guarded_changes = original

    def test_subprocess_timeout_returns_explicit_failure(self) -> None:
        original = subprocess.run
        subprocess.run = lambda *args, **kwargs: (_ for _ in ()).throw(
            subprocess.TimeoutExpired(cmd=args[0], timeout=30)
        )
        try:
            result = release_gate.run_command("stalled-verifier")
            self.assertEqual(result.returncode, 124)
            self.assertIn("timed out", result.stderr)
        finally:
            subprocess.run = original

    def test_hook_explicitly_blocks_operational_validation_exception(self) -> None:
        original_changes = release_gate.guarded_changes
        original_manifest = release_gate.manifest_path
        original_validate = release_gate.validate_manifest
        release_gate.guarded_changes = lambda _root: ["Sources/Harness/Feature.swift"]
        release_gate.manifest_path = lambda _root: Path(__file__)
        release_gate.validate_manifest = lambda *_args: (_ for _ in ()).throw(TimeoutError("stalled"))
        try:
            result = release_gate.hook(Path("."), {"last_assistant_message": "Implemented."})
            self.assertEqual(result["decision"], "block")
            self.assertIn("could not complete", result["reason"])
        finally:
            release_gate.guarded_changes = original_changes
            release_gate.manifest_path = original_manifest
            release_gate.validate_manifest = original_validate

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

    def test_counterfeit_media_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake_png = root / "fake.png"
            fake_video = root / "fake.mov"
            fake_png.write_bytes(b"not an image" * 200)
            fake_video.write_bytes(b"not a movie" * 20_000)
            self.assertTrue(release_gate.validate_png(fake_png))
            self.assertTrue(release_gate.validate_quicktime(fake_video))

    def test_wrong_artifact_types_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            directory_png = root / "visible.png"
            directory_png.mkdir()
            file_xcresult = root / "tests.xcresult"
            file_xcresult.write_text("not a result bundle", encoding="utf-8")
            self.assertIn(
                "artifact must be a regular file: screenshot",
                release_gate.artifact_type_errors("screenshot", directory_png),
            )
            self.assertIn(
                "artifact must be a directory: unit_xcresult",
                release_gate.artifact_type_errors("unit_xcresult", file_xcresult),
            )

    def test_every_repository_change_is_guarded(self) -> None:
        original = release_gate.changed_files
        release_gate.changed_files = lambda _root: {
            "scripts/sync-ontology.sh",
            ".codex/hooks.json",
            ".periphery.yml",
            ".swiftlint.yml",
            "scripts/future_gate_helper.py",
        }
        try:
            self.assertEqual(
                release_gate.guarded_changes(Path(".")),
                [
                    ".codex/hooks.json",
                    ".periphery.yml",
                    ".swiftlint.yml",
                    "scripts/future_gate_helper.py",
                    "scripts/sync-ontology.sh",
                ],
            )
        finally:
            release_gate.changed_files = original


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

    def test_unit_bundle_requires_every_protected_test(self) -> None:
        tree = {"children": [
            {"name": "HarnessTests", "nodeType": "Unit test bundle", "result": "Passed"},
            {"name": "testOne()", "nodeType": "Test Case", "nodeIdentifier": "testOne()", "result": "Passed"},
        ]}
        errors = validate_xcresult.validate_bundle_tree(
            tree, "HarnessTests", {"testOne", "testTwo"}
        )
        self.assertIn("required test bundle omitted 1 protected test(s): testTwo", errors)

    def test_protected_swift_inventory_accepts_added_tests(self) -> None:
        base = "@Test func protectedBaseTest() {}\n"
        proposed = base + "@Test func newlyAddedTest() {}\n"
        self.assertEqual(swift_test_inventory.identifiers(base), {"protectedBaseTest"})
        self.assertEqual(
            swift_test_inventory.identifiers(proposed),
            {"protectedBaseTest", "newlyAddedTest"},
        )
        tree = {"children": [
            {"name": "HarnessTests", "nodeType": "Unit test bundle", "result": "Passed"},
            {"name": "protectedBaseTest()", "nodeType": "Test Case", "nodeIdentifier": "protectedBaseTest()", "result": "Passed"},
            {"name": "newlyAddedTest()", "nodeType": "Test Case", "nodeIdentifier": "newlyAddedTest()", "result": "Passed"},
        ]}
        self.assertEqual(
            validate_xcresult.validate_bundle_tree(tree, "HarnessTests", {"protectedBaseTest"}),
            [],
        )

    def test_swift_inventory_handles_hostile_long_annotation_input_without_regex(self) -> None:
        hostile = "@A(" + ") @A(" * 100_000 + "\n@Test @MainActor func protectedTest() {}"
        self.assertEqual(swift_test_inventory.identifiers(hostile), {"protectedTest"})

    def test_swift_inventory_tracks_multiline_test_annotations_without_parsing_strings(self) -> None:
        source = '''
        @Test(
            "descriptive name"
        )
        @MainActor
        func multilineTest() {}
        let example = "func inventedTest()"
        '''
        self.assertEqual(swift_test_inventory.identifiers(source), {"multilineTest"})


class SwiftPMInventoryTests(unittest.TestCase):
    def test_missing_or_skipped_protected_test_fails(self) -> None:
        expected = ["OntologyKitTests.first()", "OntologyKitTests.second()"]
        errors = validate_swiftpm_tests.validate(
            expected,
            "✔ Test first() passed after 0.1 seconds.\n↷ Test second() skipped",
            set(),
        )
        self.assertTrue(any("omitted" in error for error in errors))
        self.assertTrue(any("skipped" in error for error in errors))


class ProtectedLiveOracleTests(unittest.TestCase):
    def test_oracle_uses_direct_network_results_and_writes_required_markers(self) -> None:
        original = live_satisfaction_oracle.request
        live_satisfaction_oracle.request = lambda url, data=None, content_type=None: (
            {"results": {"bindings": [{"s": {"value": "accepted"}}]}}
            if "3030" in url else
            ({"models": [{"name": "fixture"}]} if url.endswith("/api/tags") else {"response": "A substantive synthesis that keeps accepted authority separate from supporting context."})
        )
        try:
            with tempfile.TemporaryDirectory() as directory:
                original_argv = sys.argv
                sys.argv = ["oracle", "--commit", "a" * 40, "--output-dir", directory]
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(live_satisfaction_oracle.main(), 0)
                text = next(Path(directory).glob("gate-*.md")).read_text()
                self.assertIn("- Fuseki graph health: healthy", text)
                self.assertIn("- Direct accepted-only Fuseki preflight hits: 1", text)
        finally:
            live_satisfaction_oracle.request = original
            sys.argv = original_argv

    def test_only_live_satisfaction_test_may_be_absent(self) -> None:
        expected = ["OntologyKitTests.first()", "OntologyKitTests.satisfactionGate()"]
        self.assertEqual(
            validate_swiftpm_tests.validate(
                expected,
                "✔ Test first() passed after 0.1 seconds.",
                {"OntologyKitTests.satisfactionGate"},
            ),
            [],
        )


class CommitStatusTests(unittest.TestCase):
    def test_newest_failure_rejects_older_success(self) -> None:
        payload = {"statuses": [
            {"context": "GPT-5.6 Sol review", "state": "failure", "target_url": "new"},
            {"context": "GPT-5.6 Sol review", "state": "success", "target_url": "old"},
        ]}
        errors, _ = require_latest_status.require_latest(payload, "GPT-5.6 Sol review")
        self.assertEqual(errors, ["newest GPT-5.6 Sol review status is failure"])


class CodexAuthorizationTests(unittest.TestCase):
    def test_api_key_or_non_chatgpt_auth_is_rejected(self) -> None:
        chatgpt = {
            "auth_mode": "chatgpt",
            "OPENAI_API_KEY": None,
            "tokens": {"access_token": "token", "account_id": "account"},
        }
        self.assertEqual(verify_codex_auth.validate(chatgpt, {}), [])
        self.assertIn("OPENAI_API_KEY must be absent", verify_codex_auth.validate(chatgpt, {"OPENAI_API_KEY": "key"}))
        api = {"auth_mode": "apikey", "OPENAI_API_KEY": "key", "tokens": {}}
        self.assertTrue(verify_codex_auth.validate(api, {}))

    def test_effective_runtime_rejects_custom_provider(self) -> None:
        log = """model: gpt-5.6-sol
provider: custom-proxy
sandbox: read-only
reasoning effort: max
"""
        errors, _ = verify_codex_runtime.validate(log)
        self.assertIn(
            "effective Codex provider is custom-proxy, expected openai",
            errors,
        )
        self.assertIn(
            "ANTHROPIC_API_KEY must be absent",
            verify_codex_auth.validate(
                {"auth_mode": "chatgpt", "OPENAI_API_KEY": None, "tokens": {"access_token": "t", "account_id": "a"}},
                {"ANTHROPIC_API_KEY": "unexpected"},
            ),
        )


class RepositoryBindingTests(unittest.TestCase):
    def test_github_remote_formats_resolve_to_harness(self) -> None:
        for remote in (
            "https://github.com/dblaira/Harness.git",
            "git@github.com:dblaira/Harness.git",
            "ssh://git@github.com/dblaira/Harness.git",
        ):
            self.assertEqual(resolve_harness_repo.repository_from_remote(remote), "dblaira/Harness")

    def test_second_worktree_resolves_to_its_own_root(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory) / "Harness"
            worktree = Path(directory) / "Harness-worktree"
            subprocess.run(["git", "init", "-q", str(base)], check=True)
            subprocess.run(["git", "-C", str(base), "config", "user.email", "test@example.com"], check=True)
            subprocess.run(["git", "-C", str(base), "config", "user.name", "Gate Test"], check=True)
            (base / "README.md").write_text("fixture\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(base), "add", "README.md"], check=True)
            subprocess.run(["git", "-C", str(base), "commit", "-qm", "fixture"], check=True)
            subprocess.run(
                ["git", "-C", str(base), "remote", "add", "origin", "git@github.com:dblaira/Harness.git"],
                check=True,
            )
            subprocess.run(["git", "-C", str(base), "worktree", "add", "-qb", "codex/probe", str(worktree)], check=True)
            self.assertEqual(resolve_harness_repo.resolve(worktree), worktree.resolve())

    def test_unpushed_local_main_commit_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            remote = root / "remote.git"
            local = root / "local"
            subprocess.run(["git", "init", "--bare", "-q", str(remote)], check=True)
            subprocess.run(["git", "init", "-q", "-b", "main", str(local)], check=True)
            subprocess.run(["git", "-C", str(local), "config", "user.email", "test@example.com"], check=True)
            subprocess.run(["git", "-C", str(local), "config", "user.name", "Gate Test"], check=True)
            subprocess.run(["git", "-C", str(local), "remote", "add", "origin", str(remote)], check=True)
            (local / "control.txt").write_text("reviewed\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(local), "add", "control.txt"], check=True)
            subprocess.run(["git", "-C", str(local), "commit", "-qm", "reviewed"], check=True)
            subprocess.run(["git", "-C", str(local), "push", "-q", "-u", "origin", "main"], check=True)
            resolve_harness_repo.require_remote_ref(local, "refs/heads/main")
            (local / "control.txt").write_text("unreviewed\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(local), "commit", "-qam", "unpushed"], check=True)
            with self.assertRaisesRegex(ValueError, "does not equal protected origin"):
                resolve_harness_repo.require_remote_ref(local, "refs/heads/main")

    def test_stop_router_blocks_harness_checkout_with_missing_origin(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "Harness"
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            (root / ".github").mkdir()
            (root / ".github/acceptance-contract.json").write_text("{}\n", encoding="utf-8")
            (root / "project.yml").write_text("name: Harness\n", encoding="utf-8")
            (root / "Sources/Harness").mkdir(parents=True)
            with self.assertRaisesRegex(ValueError, "Stop gate stays closed"):
                route_stop_gate.route(root, root)

    def test_stop_router_allows_unrelated_repository(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "Other"
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            self.assertIsNone(route_stop_gate.route(root, Path(directory) / "Harness"))

    def test_stop_router_blocks_unreadable_git_inside_installed_harness_root(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "Harness"
            root.mkdir()
            with self.assertRaisesRegex(ValueError, "Git metadata is unreadable"):
                route_stop_gate.route(root, root)

    def test_stop_router_blocks_unreadable_secondary_harness_clone(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "secondary" / "Harness"
            (root / ".github").mkdir(parents=True)
            (root / ".github/acceptance-contract.json").write_text("{}\n", encoding="utf-8")
            (root / "project.yml").write_text("name: Harness\n", encoding="utf-8")
            (root / "Sources/Harness").mkdir(parents=True)
            with self.assertRaisesRegex(ValueError, "Git metadata is unreadable"):
                route_stop_gate.route(root / "Sources/Harness", Path(directory) / "installed" / "Harness")


class EvidenceBindingTests(unittest.TestCase):
    def test_binding_changes_for_pr_base_or_full_contract(self) -> None:
        first = evidence_binding.binding_digest("dblaira/Harness", 19, "a" * 40, "b" * 40, "c" * 64)
        self.assertNotEqual(
            first,
            evidence_binding.binding_digest("dblaira/Harness", 20, "a" * 40, "b" * 40, "c" * 64),
        )
        self.assertNotEqual(
            first,
            evidence_binding.binding_digest("dblaira/Harness", 19, "e" * 40, "b" * 40, "c" * 64),
        )
        self.assertNotEqual(
            first,
            evidence_binding.binding_digest("dblaira/Harness", 19, "a" * 40, "b" * 40, "f" * 64),
        )

    def test_two_open_pull_requests_sharing_a_sha_are_rejected(self) -> None:
        sha = "b" * 40
        pulls = [
            {"state": "open", "number": 19, "base": {"ref": "main"}, "head": {"sha": sha}},
            {"state": "open", "number": 20, "base": {"ref": "main"}, "head": {"sha": sha}},
        ]
        with self.assertRaisesRegex(ValueError, "exactly one open pull request"):
            select_pull_request.select_pull_request(pulls, sha)

    def test_non_main_pull_request_is_rejected(self) -> None:
        sha = "b" * 40
        pulls = [
            {"state": "open", "number": 19, "base": {"ref": "release"}, "head": {"sha": sha}},
        ]
        with self.assertRaisesRegex(ValueError, "targeting main"):
            select_pull_request.select_pull_request(pulls, sha)

    def test_non_agent_branch_is_rejected(self) -> None:
        sha = "b" * 40
        pulls = [{
            "state": "open", "number": 19,
            "base": {"ref": "main"},
            "head": {"sha": sha, "ref": "feature/manual"},
        }]
        with self.assertRaisesRegex(ValueError, "agent-owned codex/ branch"):
            select_pull_request.select_pull_request(pulls, sha)


class PeripheryChangedLineTests(unittest.TestCase):
    def test_legacy_findings_are_ignored_but_changed_line_findings_block(self) -> None:
        root = Path("/proposal")
        diff = """diff --git a/Feature.swift b/Feature.swift
--- a/Feature.swift
+++ b/Feature.swift
@@ -9,0 +10,2 @@
+let changed = true
+let alsoChanged = true
"""
        changed = periphery_changed_gate.parse_changed_lines(diff, root)
        findings = [
            {"name": "legacy", "location": "/proposal/Feature.swift:3:1"},
            {"name": "new", "location": "/proposal/Feature.swift:10:1"},
        ]
        self.assertEqual(
            periphery_changed_gate.changed_findings(findings, changed, root),
            [findings[1]],
        )

    def test_malformed_finding_location_fails_closed(self) -> None:
        with self.assertRaisesRegex(ValueError, "no parseable location"):
            periphery_changed_gate.changed_findings(
                [{"name": "unknown schema"}],
                {},
                Path("/proposal"),
            )

    def test_relative_or_outside_location_fails_closed(self) -> None:
        for location in ("Feature.swift:10:1", "/dependency/Feature.swift:10:1"):
            with self.assertRaisesRegex(ValueError, "invalid location"):
                periphery_changed_gate.changed_findings(
                    [{"name": "bad", "location": location}],
                    {},
                    Path("/proposal"),
                )

    def test_deletion_only_hunk_has_no_head_lines_to_gate(self) -> None:
        diff = """diff --git a/Feature.swift b/Feature.swift
--- a/Feature.swift
+++ b/Feature.swift
@@ -4,2 +4,0 @@
-let deleted = true
-let removed = true
"""
        changed = periphery_changed_gate.parse_changed_lines(diff, Path("/proposal"))
        self.assertFalse(any(changed.values()))

    def test_deleted_file_cannot_attach_hunks_to_previous_file(self) -> None:
        diff = """diff --git a/Kept.swift b/Kept.swift
--- a/Kept.swift
+++ b/Kept.swift
@@ -1,0 +2,1 @@
+let kept = true
diff --git a/Deleted.swift b/Deleted.swift
--- a/Deleted.swift
+++ /dev/null
@@ -1,1 +0,0 @@
-let deleted = true
"""
        changed = periphery_changed_gate.parse_changed_lines(diff, Path("/proposal"))
        self.assertEqual(changed[Path("/proposal/Kept.swift")], {2})

    def test_unicode_swift_path_is_enumerated_without_git_header_quoting(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["git", "init", "-q", "-b", "main", str(root)], check=True)
            subprocess.run(["git", "-C", str(root), "config", "user.email", "test@example.com"], check=True)
            subprocess.run(["git", "-C", str(root), "config", "user.name", "Gate Test"], check=True)
            (root / "README.md").write_text("base\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(root), "add", "."], check=True)
            subprocess.run(["git", "-C", str(root), "commit", "-qm", "base"], check=True)
            base = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
            path = root / "évidence.swift"
            path.write_text("let unusedEvidence = true\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(root), "add", "."], check=True)
            subprocess.run(["git", "-C", str(root), "commit", "-qm", "unicode"], check=True)
            changed = periphery_changed_gate.changed_swift_lines(root, base)
            self.assertEqual(changed[path.resolve()], {1})
            finding = {"name": "unusedEvidence", "location": f"{path.resolve()}:1:1"}
            self.assertEqual(periphery_changed_gate.changed_findings([finding], changed, root), [finding])


class AppIdentityTests(unittest.TestCase):
    def test_wrong_bundle_identifier_is_rejected_before_launch(self) -> None:
        entitlements = dict(verify_app_identity.REQUIRED_ENTITLEMENTS)
        signature = "TeamIdentifier=7FKUS5M5QS\nCDHash=abc123\n"
        requirement = 'designated => identifier "com.adamblair.Harness" and anchor apple generic'
        errors, _ = verify_app_identity.validate_identity(
            "com.attacker.Substitute", signature, requirement, entitlements
        )
        self.assertIn(
            "bundle identifier is com.attacker.Substitute, expected com.adamblair.Harness",
            errors,
        )


class MediaEvidenceTests(unittest.TestCase):
    def test_valid_blank_png_and_video_are_rejected(self) -> None:
        self.assertIsNotNone(shutil.which("ffmpeg"), "ffmpeg is a mandatory handoff dependency")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            png = root / "blank.png"
            video = root / "blank.mov"
            subprocess.run(
                [
                    "ffmpeg", "-v", "error", "-f", "lavfi", "-i", "color=black:s=320x240",
                    "-frames:v", "1", "-update", "1", str(png),
                ],
                check=True,
            )
            subprocess.run(
                [
                    "ffmpeg", "-v", "error", "-f", "lavfi", "-i", "color=black:s=320x240:d=2",
                    "-c:v", "mpeg4", "-pix_fmt", "yuv420p", str(video),
                ],
                check=True,
            )
            self.assertTrue(any("blank" in error or "black" in error for error in validate_media.validate_png_file(png)))
            self.assertTrue(any("nonblank" in error for error in validate_media.validate_video_file(video)))


class ReviewBundleSanitizationTests(unittest.TestCase):
    def test_symlinked_agents_instruction_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "payload.txt").write_text("untrusted instructions", encoding="utf-8")
            (root / "AGENTS.md").symlink_to(root / "payload.txt")
            errors = sanitize_review_bundle.sanitize([root])
            self.assertTrue(any("forbidden symlink" in error for error in errors))

    def test_regular_nested_agents_file_is_removed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            nested = root / "nested"
            nested.mkdir()
            agents = nested / "AGENTS.md"
            agents.write_text("untrusted instructions", encoding="utf-8")
            self.assertEqual(sanitize_review_bundle.sanitize([root]), [])
            self.assertFalse(agents.exists())


class ProtectedVerifierTests(unittest.TestCase):
    def test_zero_exit_without_full_inventory_is_rejected(self) -> None:
        errors = run_gate_script_tests.validate_transcript("", {"test_one", "test_two"}, 0)
        self.assertIn("protected gate test inventory did not complete", errors)
        self.assertIn("protected gate tests did not report OK", errors)

    def test_fresh_report_validator_rejects_incomplete_inventory(self) -> None:
        errors = validate_gate_test_report.validate({
            "status": "PASS",
            "expected_test_count": 2,
            "completed_test_count": 0,
            "errors": [],
            "transcript": "OK",
        })
        self.assertIn("gate test report has incomplete inventory", errors)


class HostedAuthorityTests(unittest.TestCase):
    def test_every_gate_authority_input_requires_the_bootstrap_path(self) -> None:
        protected = (
            "scripts/tests/test_gates.py",
            ".swiftlint.yml",
            ".periphery.yml",
            "scripts/preflight_tcc.swift",
            "Tests/HarnessUITests/HarnessCriticalFlowTests.swift",
            "Tests/HarnessUITests/HarnessRequirementEvidence.swift",
            "Packages/OntologyKit/Tests/OntologyKitTests/SatisfactionGateLiveTests.swift",
        )
        for relative in protected:
            with self.subTest(path=relative), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                subprocess.run(["git", "init", "-q", "-b", "main", str(root)], check=True)
                subprocess.run(["git", "-C", str(root), "config", "user.email", "test@example.com"], check=True)
                subprocess.run(["git", "-C", str(root), "config", "user.name", "Gate Test"], check=True)
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("protected\n", encoding="utf-8")
                subprocess.run(["git", "-C", str(root), "add", "."], check=True)
                subprocess.run(["git", "-C", str(root), "commit", "-qm", "base"], check=True)
                base = subprocess.check_output(
                    ["git", "-C", str(root), "rev-parse", "HEAD"], text=True
                ).strip()
                path.write_text("weakened\n", encoding="utf-8")
                subprocess.run(["git", "-C", str(root), "commit", "-qam", "proposal"], check=True)
                head = subprocess.check_output(
                    ["git", "-C", str(root), "rev-parse", "HEAD"], text=True
                ).strip()
                self.assertTrue(verify_hosted_evidence.unchanged_protected_controls(root, base, head))

    def test_spoofed_status_workflow_event_is_rejected(self) -> None:
        status = {"state": "success", "creator": {"login": "github-actions[bot]"}}
        run = {
            "path": ".github/workflows/acceptance-contract.yml",
            "event": "pull_request",
            "head_sha": "b" * 40,
            "conclusion": "success",
            "repository": {"full_name": "dblaira/Harness"},
        }
        errors = verify_hosted_evidence.validate_status(
            "Acceptance contract", status, run, "dblaira/Harness", "b" * 40
        )
        self.assertIn("hosted status came from the wrong protected workflow: Acceptance contract", errors)

    def test_spoofed_local_merge_status_creator_is_rejected(self) -> None:
        marker = "pr:20 binding:abc"
        payload = [
            {
                "context": context,
                "state": "success",
                "creator": {"login": "github-actions[bot]"},
                "description": marker,
                "target_url": "https://github.com/dblaira/Harness/pull/20",
            }
            for context in verify_merge_authority.REQUIRED
        ]
        self.assertTrue(any("wrong creator" in error for error in verify_merge_authority.validate(payload, marker)))


class RepositoryGateStateTests(unittest.TestCase):
    def test_each_drifted_repository_setting_fails_closed(self) -> None:
        repository = {"allow_merge_commit": True, "allow_squash_merge": False, "allow_rebase_merge": False}
        protection = {
            "required_status_checks": {"strict": True, "contexts": sorted(verify_repository_gate_state.REQUIRED_CONTEXTS)},
            "enforce_admins": {"enabled": True},
            "required_pull_request_reviews": {"required_approving_review_count": 0},
            "required_conversation_resolution": {"enabled": True},
            "allow_force_pushes": {"enabled": False},
            "allow_deletions": {"enabled": False},
            "required_linear_history": {"enabled": False},
        }
        actions = {"enabled": True, "allowed_actions": "selected", "sha_pinning_required": True}
        workflow = {"default_workflow_permissions": "read", "can_approve_pull_request_reviews": False}
        selected = {"github_owned_allowed": True, "verified_allowed": False, "patterns_allowed": []}
        runners = {"total_count": 0}
        self.assertEqual(
            verify_repository_gate_state.validate(repository, protection, actions, workflow, selected, runners),
            [],
        )
        cases = []
        drifted = copy.deepcopy(protection); drifted["required_status_checks"]["strict"] = False
        cases.append((repository, drifted, actions, workflow, selected, runners))
        drifted = copy.deepcopy(protection); drifted["enforce_admins"]["enabled"] = False
        cases.append((repository, drifted, actions, workflow, selected, runners))
        drifted = copy.deepcopy(protection); drifted["required_pull_request_reviews"] = None
        cases.append((repository, drifted, actions, workflow, selected, runners))
        drifted = copy.deepcopy(protection); drifted["required_conversation_resolution"]["enabled"] = False
        cases.append((repository, drifted, actions, workflow, selected, runners))
        drifted = copy.deepcopy(protection); drifted["allow_force_pushes"]["enabled"] = True
        cases.append((repository, drifted, actions, workflow, selected, runners))
        drifted = copy.deepcopy(protection); drifted["allow_deletions"]["enabled"] = True
        cases.append((repository, drifted, actions, workflow, selected, runners))
        drifted = copy.deepcopy(protection); drifted["required_linear_history"]["enabled"] = True
        cases.append((repository, drifted, actions, workflow, selected, runners))
        cases.append((repository | {"allow_squash_merge": True}, protection, actions, workflow, selected, runners))
        cases.append((repository, protection, actions | {"allowed_actions": "all"}, workflow, selected, runners))
        cases.append((repository, protection, actions | {"sha_pinning_required": False}, workflow, selected, runners))
        cases.append((repository, protection, actions, workflow | {"default_workflow_permissions": "write"}, selected, runners))
        cases.append((repository, protection, actions, workflow | {"can_approve_pull_request_reviews": True}, selected, runners))
        cases.append((repository, protection, actions, workflow, selected | {"verified_allowed": True}, runners))
        cases.append((repository, protection, actions, workflow, selected, {"total_count": 1}))
        for case in cases:
            self.assertTrue(verify_repository_gate_state.validate(*case))

    def test_outdated_installed_control_bundle_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory) / "repo"
            controls = Path(directory) / "controls"
            subprocess.run(["git", "init", "-q", "-b", "main", str(repo)], check=True)
            subprocess.run(["git", "-C", str(repo), "config", "user.email", "test@example.com"], check=True)
            subprocess.run(["git", "-C", str(repo), "config", "user.name", "Gate Test"], check=True)
            (repo / "scripts").mkdir()
            (repo / "scripts/control.py").write_text("current\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(repo), "add", "."], check=True)
            subprocess.run(["git", "-C", str(repo), "commit", "-qm", "base"], check=True)
            base = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
            (controls / "scripts").mkdir(parents=True)
            (controls / "scripts/control.py").write_text("stale\n", encoding="utf-8")
            manifest = {"files": {"scripts/control.py": verify_control_bundle.digest(b"stale\n")}}
            errors = verify_control_bundle.validate(manifest, controls, repo, base)
            self.assertIn("installed control is stale relative to protected base: scripts/control.py", errors)


class SwiftLintGateTests(unittest.TestCase):
    def test_changed_file_discovery_failure_cannot_report_success(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            fake_git = fake_bin / "git"
            fake_git.write_text(
                "#!/usr/bin/env bash\n"
                "if [[ \"$1 $2\" == \"rev-parse --show-toplevel\" ]]; then pwd; exit 0; fi\n"
                "if [[ \"$1\" == \"cat-file\" ]]; then exit 0; fi\n"
                "if [[ \"$1\" == \"diff\" ]]; then echo 'sentinel diff failure' >&2; exit 7; fi\n"
                "exit 1\n",
                encoding="utf-8",
            )
            fake_git.chmod(0o755)
            environment = dict(os.environ)
            environment["PATH"] = f"{fake_bin}:{environment.get('PATH', '')}"
            result = subprocess.run(
                ["/bin/bash", str(SCRIPTS / "lint_changed_swift.sh"), "fixture-base"],
                cwd=root,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Unable to inspect Swift changes", result.stderr)


class InstructionConsistencyTests(unittest.TestCase):
    def test_swift_rules_require_agent_owned_pull_request(self) -> None:
        root = Path.cwd()
        combined = "\n".join(
            (root / path).read_text(encoding="utf-8")
            for path in (".cursor/rules/ios-main-only.mdc", ".cursor/rules/stack-ios.mdc")
        )
        self.assertIn("agent-owned", combined)
        self.assertNotIn("push to **main**", combined)


class GateStructureTests(unittest.TestCase):
    def test_handoff_checks_sol_and_head_before_proposed_execution(self) -> None:
        handoff = (Path.cwd() / "script/handoff_gate.sh").read_text(encoding="utf-8")
        self.assertLess(handoff.index("SOL_URL="), handoff.index("xcodegen generate"))
        self.assertLess(handoff.index("PR_HEAD_SHA="), handoff.index("xcodegen generate"))
        self.assertGreaterEqual(handoff.count("--jq .head.sha"), 1)
        self.assertIn("FINAL_PR_HEAD=", handoff)
        self.assertLess(handoff.index("preflight_tcc.swift"), handoff.index("xcodegen generate"))

    def test_installed_stop_hook_has_validation_budget_and_replaces_stale_entry(self) -> None:
        installer = (Path.cwd() / "script/install_local_gate_controls.sh").read_text(encoding="utf-8")
        self.assertIn('"timeout": 300', installer)
        self.assertIn("hooks[:] = [entry for entry in hooks", installer)

    def test_merge_revalidates_hosted_evidence_immediately_before_status_authority(self) -> None:
        merger = (Path.cwd() / "script/merge_verified_pr.sh").read_text(encoding="utf-8")
        rerun = merger.index('if ! "$CONTROL_DIR/script/hosted_verification_gate.sh"')
        failure_exit = merger.index('Fresh hosted evidence verification failed')
        status_read = merger.index('gh api "repos/$REPO/commits/$SHA/statuses?per_page=100"')
        merge = merger.index('gh pr merge')
        self.assertLess(rerun, failure_exit)
        self.assertLess(failure_exit, status_read)
        self.assertLess(rerun, status_read)
        self.assertLess(status_read, merge)

    def test_video_is_bound_to_the_verified_candidate_window_not_main_display(self) -> None:
        handoff = (Path.cwd() / "script/handoff_gate.sh").read_text(encoding="utf-8")
        self.assertIn('-l"$RECORDED_WINDOW_ID"', handoff)
        self.assertNotIn("screencapture -v -V120 -m", handoff)
        self.assertIn("recorded_running_app_proof", handoff)

    def test_ui_assertion_and_screenshot_share_expected_process_and_window(self) -> None:
        ui_test = (Path.cwd() / "Tests/HarnessUITests/HarnessCriticalFlowTests.swift").read_text(encoding="utf-8")
        handoff = (Path.cwd() / "script/handoff_gate.sh").read_text(encoding="utf-8")
        self.assertIn("HARNESS_EXPECTED_PID", ui_test)
        self.assertIn("HarnessProcess-\\(expectedPID)", ui_test)
        self.assertIn("HARNESS_EXPECTED_WINDOW_BOUNDS", ui_test)
        self.assertIn("window.descendants(matching: .any)[requiredIdentifier]", ui_test)
        self.assertNotIn("app.descendants(matching: .any)[requiredIdentifier]", ui_test)
        self.assertIn("attachVisibleResult(of: window", ui_test)
        self.assertGreaterEqual(handoff.count("HARNESS_EXPECTED_WINDOW_BOUNDS="), 3)
        self.assertIn('UI_TEST_ARGS=("-only-testing:$BINDING_UI_TEST")', handoff)
        self.assertIn('UI_TEST_ARGS+=("-only-testing:$UI_TEST")', handoff)
        self.assertIn('--required-test "$UI_TEST" --max-duration 55 --screenshot-output "$FEATURE_SCREENSHOT"', handoff)
        self.assertIn('cmp -s "$FEATURE_SCREENSHOT" "$SCREENSHOT"', handoff)
        self.assertIn('--required-test "$BINDING_UI_TEST"', handoff)

    def test_live_satisfaction_oracle_change_is_rejected_before_handoff_execution(self) -> None:
        handoff = (Path.cwd() / "script/handoff_gate.sh").read_text(encoding="utf-8")
        protected = "Packages/OntologyKit/Tests/OntologyKitTests/SatisfactionGateLiveTests.swift"
        self.assertIn(protected, verify_hosted_evidence.PROTECTED_CONTROL_PATHS)
        self.assertLess(handoff.index("hosted_verification_gate.sh"), handoff.index("live_satisfaction_oracle.py"))
        oracle = (Path.cwd() / "scripts/live_satisfaction_oracle.py").read_text(encoding="utf-8")
        for proposal_type in ("FusekiGraphHealthChecker", "HarnessRunService", "AgentRunnerBackendAdapter"):
            self.assertNotIn(proposal_type, oracle)

    def test_protected_test_inventory_is_rebuilt_after_proposal_execution(self) -> None:
        handoff = (Path.cwd() / "script/handoff_gate.sh").read_text(encoding="utf-8")
        final_inventory = handoff.rindex('swift_test_inventory.py"')
        final_app_test = handoff.rindex('validate_media.py"')
        manifest = handoff.index("MID_PR_HEAD=")
        self.assertLess(final_app_test, final_inventory)
        self.assertLess(final_inventory, manifest)

    def test_signature_identity_precedes_first_app_test_or_launch(self) -> None:
        handoff = (Path.cwd() / "script/handoff_gate.sh").read_text(encoding="utf-8")
        identity = handoff.index("verify_app_identity.py")
        unit_test = handoff.index("xcodebuild test \\")
        ui_test = handoff.index("xcodebuild test-without-building")
        normal_launch = handoff.index("/usr/bin/open -n")
        self.assertLess(identity, unit_test)
        self.assertLess(identity, ui_test)
        self.assertLess(identity, normal_launch)

    def test_permanent_installer_has_no_mutable_pr_bootstrap(self) -> None:
        installer = (Path.cwd() / "script/install_local_gate_controls.sh").read_text(encoding="utf-8")
        merge_gate = (Path.cwd() / "script/install_merge_gate.sh").read_text(encoding="utf-8")
        self.assertNotIn("--bootstrap-pr", installer)
        self.assertNotIn("--bootstrap", merge_gate)
        self.assertIn("verify_repository_gate_state.py", installer)
        self.assertIn("--require-ref refs/heads/main", installer)

    def test_hosted_evidence_is_exact_head_bound_and_forks_are_rejected(self) -> None:
        verification = (Path.cwd() / ".github/workflows/verification.yml").read_text(encoding="utf-8")
        acceptance = (Path.cwd() / ".github/workflows/acceptance-contract.yml").read_text(encoding="utf-8")
        self.assertIn("github.event.pull_request.head.sha", verification)
        self.assertIn("run_gate_script_tests.py", verification)
        self.assertIn("Fresh protected gate evidence verifier", verification)
        self.assertIn("Fresh protected macOS evidence verifier", verification)
        self.assertIn("Fork pull requests are not accepted", acceptance)

    def test_periphery_uses_protected_configuration(self) -> None:
        verification = (Path.cwd() / ".github/workflows/verification.yml").read_text(encoding="utf-8")
        periphery = (Path.cwd() / "scripts/periphery_changed_gate.py").read_text(encoding="utf-8")
        self.assertIn("trusted-base/.periphery.yml", verification)
        self.assertIn('--config", str(config)', periphery)
        protected = Path("/trusted/periphery.yml")
        arguments = periphery_changed_gate.scan_arguments(
            protected, Path("/tmp/findings.json")
        )
        self.assertEqual(arguments[arguments.index("--config") + 1], str(protected))
        self.assertNotIn("/proposal/.periphery.yml", arguments)
        self.assertNotIn("--report-include", arguments)
        self.assertNotIn("--strict", arguments)

    def test_local_statuses_include_pr_specific_evidence_binding(self) -> None:
        sol = (Path.cwd() / "script/sol_review_gate.sh").read_text(encoding="utf-8")
        handoff = (Path.cwd() / "script/handoff_gate.sh").read_text(encoding="utf-8")
        for source in (sol, handoff):
            self.assertIn("select_pull_request.py", source)
            self.assertIn("EVIDENCE_BINDING", source)
            self.assertIn("pr:$PR_NUMBER binding:", source)

    def test_acceptance_authority_is_fully_commit_bound(self) -> None:
        contract = json.loads((Path.cwd() / ".github/acceptance-contract.json").read_text(encoding="utf-8"))
        self.assertEqual(validate_acceptance_contract.validate_handoff_contract(
            contract,
            repo=validate_acceptance_contract.BOOTSTRAP_REPO,
            pr_number=validate_acceptance_contract.BOOTSTRAP_PR,
            base_sha=validate_acceptance_contract.BOOTSTRAP_BASE,
        ), [])
        acceptance_workflow = (Path.cwd() / ".github/workflows/acceptance-contract.yml").read_text(encoding="utf-8")
        sol_workflow = (Path.cwd() / ".github/workflows/sol-review.yml").read_text(encoding="utf-8")
        validator = (Path.cwd() / "scripts/validate_acceptance_contract.py").read_text(encoding="utf-8")
        self.assertNotIn("PR_BODY", acceptance_workflow)
        self.assertNotIn("edited", acceptance_workflow)
        self.assertNotIn("edited", sol_workflow)
        self.assertNotIn("--pr-body-file", validator)
        self.assertNotIn("pr_contract_digest", validator)

    def test_sol_runtime_is_pinned_to_official_provider(self) -> None:
        reviewer = (Path.cwd() / "script/sol_review_gate.sh").read_text(encoding="utf-8")
        self.assertIn("--ignore-user-config", reviewer)
        self.assertIn('model_provider="openai"', reviewer)
        self.assertIn("verify_codex_runtime.py", reviewer)

    def test_review_diff_is_direct_base_to_head_on_diverged_history(self) -> None:
        reviewer = (Path.cwd() / "script/sol_review_gate.sh").read_text(encoding="utf-8")
        self.assertIn('git diff --binary --find-renames "$BASE_SHA" "$HEAD_SHA"', reviewer)
        self.assertNotIn('$BASE_SHA...$HEAD_SHA', reviewer)
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            subprocess.run(["git", "init", "-q", "-b", "main", str(repo)], check=True)
            subprocess.run(["git", "-C", str(repo), "config", "user.email", "test@example.com"], check=True)
            subprocess.run(["git", "-C", str(repo), "config", "user.name", "Gate Test"], check=True)
            (repo / "shared.txt").write_text("base\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(repo), "add", "."], check=True)
            subprocess.run(["git", "-C", str(repo), "commit", "-qm", "base"], check=True)
            base = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
            subprocess.run(["git", "-C", str(repo), "switch", "-qc", "feature"], check=True)
            (repo / "feature.txt").write_text("feature-only\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(repo), "add", "."], check=True)
            subprocess.run(["git", "-C", str(repo), "commit", "-qm", "feature"], check=True)
            head = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
            subprocess.run(["git", "-C", str(repo), "switch", "-q", "main"], check=True)
            (repo / "main.txt").write_text("main-only\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(repo), "add", "."], check=True)
            subprocess.run(["git", "-C", str(repo), "commit", "-qm", "advanced base"], check=True)
            advanced_base = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
            direct = subprocess.check_output(["git", "-C", str(repo), "diff", advanced_base, head], text=True)
            triple = subprocess.check_output(["git", "-C", str(repo), "diff", f"{advanced_base}...{head}"], text=True)
            self.assertIn("main.txt", direct)
            self.assertIn("feature.txt", direct)
            self.assertNotIn("main.txt", triple)
            self.assertNotEqual(base, advanced_base)

    def test_rejection_probe_never_pushes_to_production_main(self) -> None:
        probe = (Path.cwd() / "script/prove_merge_gate.sh").read_text(encoding="utf-8")
        self.assertNotIn("HEAD:main", probe)
        self.assertIn("$PROBE_SHA:refs/heads/$PROBE_BASE", probe)
        self.assertIn("Production main changed", probe)


class ReleaseTreeTests(unittest.TestCase):
    def test_merge_commit_attests_exact_verified_tree_and_checks(self) -> None:
        merge, first, head, tree = "m" * 40, "a" * 40, "b" * 40, "t" * 40
        status_contexts = set(verify_release_tree.REQUIRED_STATUS_CONTEXTS)
        statuses = [{
            "context": context,
            "state": "success",
            "target_url": f"https://example/{context}",
            "creator": {"login": verify_release_tree.REQUIRED_STATUS_CONTEXTS[context]},
            "description": "success pr:19 binding:abcdef",
        } for context in status_contexts]
        checks = {"check_runs": [
            {
                "name": context,
                "status": "completed",
                "conclusion": "success",
                "html_url": f"https://example/{context}",
                "app": {"slug": "github-actions"},
            }
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

    def test_unbound_local_status_is_rejected(self) -> None:
        context = "Trusted hosted verification"
        statuses = [{
            "context": context,
            "state": "success",
            "creator": {"login": "dblaira"},
            "target_url": "https://example/status",
            "description": "success without contract binding",
        }]
        errors, _ = verify_release_tree.validate(
            "m" * 40,
            f"{'m' * 40} {'a' * 40} {'b' * 40}",
            "t" * 40,
            "t" * 40,
            statuses,
            {"check_runs": []},
        )
        self.assertIn(
            "required status lacks PR and contract binding: Trusted hosted verification",
            errors,
        )


if __name__ == "__main__":
    unittest.main()
