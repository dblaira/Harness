from __future__ import annotations

import copy
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from stage_candidate import CandidateStageError, stage_candidate, validate_candidate
from review_queue_transaction import coordinated_compare_and_swap


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]


def valid_candidate() -> dict:
    return {
        "id": "cand-understood-2026-07-10-meaningful-proof",
        "status": "pending",
        "plain": "AGENT PROPOSAL: Adam's accepted evidence should change one named decision.",
        "evidence": "Exact source wording with a durable source reference.",
        "source": "understood:test-fixture",
        "domain_a": "belief",
        "domain_b": "work",
        "strength": 0.8,
        "connection_type": "confirmed_personal_axiom",
    }


class StageCandidateTests(unittest.TestCase):
    def make_ontology(self, queue: list[dict] | None = None) -> tuple[tempfile.TemporaryDirectory, Path]:
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name)
        candidates = root / "candidates"
        candidates.mkdir(parents=True)
        (candidates / "queue.json").write_text(json.dumps(queue or [], indent=2) + "\n")
        return temporary, root

    def test_dry_run_validates_without_writing(self) -> None:
        temporary, root = self.make_ontology()
        with temporary:
            queue_path = root / "candidates/queue.json"
            before = queue_path.read_bytes()
            result = stage_candidate(
                valid_candidate(), root, REPOSITORY_ROOT, dry_run=True
            )
            self.assertEqual(result["outcome"], "validated-dry-run")
            self.assertEqual(result["shacl"], "passed")
            self.assertEqual(queue_path.read_bytes(), before)

    def test_real_stage_writes_only_pending_queue_entry(self) -> None:
        existing = [{"id": "old", "status": "accepted"}]
        temporary, root = self.make_ontology(existing)
        with temporary:
            result = stage_candidate(valid_candidate(), root, REPOSITORY_ROOT)
            queue = json.loads((root / "candidates/queue.json").read_text())
            self.assertEqual(result["outcome"], "staged")
            self.assertEqual(queue[-1], valid_candidate())
            self.assertFalse((root / "accepted").exists())

    def test_idempotent_exact_candidate_is_noop(self) -> None:
        candidate = valid_candidate()
        temporary, root = self.make_ontology([candidate])
        with temporary:
            queue_path = root / "candidates/queue.json"
            before = queue_path.read_bytes()
            result = stage_candidate(candidate, root, REPOSITORY_ROOT)
            self.assertEqual(result["outcome"], "already-present")
            self.assertEqual(queue_path.read_bytes(), before)

    def test_same_id_with_different_content_is_blocked(self) -> None:
        candidate = valid_candidate()
        changed = copy.deepcopy(candidate)
        changed["evidence"] = "Different evidence."
        temporary, root = self.make_ontology([candidate])
        with temporary:
            with self.assertRaisesRegex(CandidateStageError, "different content"):
                stage_candidate(changed, root, REPOSITORY_ROOT)

    def test_existing_pending_candidate_is_fail_closed(self) -> None:
        existing = copy.deepcopy(valid_candidate())
        existing["id"] = "cand-existing"
        temporary, root = self.make_ontology([existing])
        with temporary:
            with self.assertRaisesRegex(CandidateStageError, "already has 1 pending"):
                stage_candidate(valid_candidate(), root, REPOSITORY_ROOT)

    def test_expected_queue_hash_prevents_stale_write(self) -> None:
        temporary, root = self.make_ontology()
        with temporary:
            with self.assertRaisesRegex(CandidateStageError, "changed since"):
                stage_candidate(
                    valid_candidate(),
                    root,
                    REPOSITORY_ROOT,
                    expected_queue_sha="0" * 64,
                )

    def test_coordinated_compare_and_swap_preserves_a_newer_queue(self) -> None:
        temporary, root = self.make_ontology()
        with temporary:
            queue_path = root / "candidates/queue.json"
            expected = queue_path.read_bytes()
            newer = [{"id": "cand-written-by-running-harness", "status": "pending"}]
            queue_path.write_text(json.dumps(newer, indent=2) + "\n")
            replacement = json.dumps([valid_candidate()], indent=2).encode()

            replaced = coordinated_compare_and_swap(
                queue_path,
                expected,
                replacement,
                repository_root=REPOSITORY_ROOT,
            )

            self.assertFalse(replaced)
            self.assertEqual(json.loads(queue_path.read_text()), newer)

    def test_candidate_must_be_pending_agent_proposal(self) -> None:
        candidate = valid_candidate()
        candidate["status"] = "accepted"
        with self.assertRaisesRegex(CandidateStageError, "status must be pending"):
            validate_candidate(candidate)

        candidate = valid_candidate()
        candidate["plain"] = "A hidden agent claim."
        with self.assertRaisesRegex(CandidateStageError, "AGENT PROPOSAL"):
            validate_candidate(candidate)

    def test_unknown_domain_and_field_are_blocked(self) -> None:
        candidate = valid_candidate()
        candidate["domain_a"] = "productivity"
        with self.assertRaisesRegex(CandidateStageError, "allowed life domain"):
            validate_candidate(candidate)

        candidate = valid_candidate()
        candidate["accepted"] = True
        with self.assertRaisesRegex(CandidateStageError, "unsupported fields"):
            validate_candidate(candidate)


if __name__ == "__main__":
    unittest.main()
