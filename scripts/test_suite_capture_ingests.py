from __future__ import annotations

import datetime as dt
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))

import ingest_boring_news
import ingest_recall


EXPECTED_CAPTURE_FIELDS = {
    "schema_version",
    "capture_id",
    "captured_at",
    "capture_kind",
    "source_app",
    "source_record_id",
    "payload",
    "artifact_refs",
}
CANDIDATE_FIELDS = {
    "plain",
    "evidence",
    "domain_a",
    "domain_b",
    "strength",
    "connection_type",
}


class SuiteCaptureIngestTests(unittest.TestCase):
    def test_recall_reader_emits_raw_reminder_capture_without_candidate_decision(self) -> None:
        reminder = {
            "id": "reminder-1",
            "kind": "action",
            "status": "open",
            "list_name": "Build",
            "due_date": "2026-07-12",
            "created_at": "2026-07-11T18:00:00Z",
        }
        with tempfile.TemporaryDirectory() as temporary:
            inbox = Path(temporary) / "Harness Captures/Pending"
            with patch.object(ingest_recall, "fetch_reminders", return_value=[reminder]), patch.object(
                ingest_recall,
                "fetch_tags",
                return_value={"reminder-1": ["project", "follow up"]},
            ):
                result = ingest_recall.run(inbox)

            self.assertEqual(result["captures_emitted"], 1)
            files = list(inbox.glob("*.json"))
            self.assertEqual(len(files), 1)
            capture = json.loads(files[0].read_text())
            self.assertEqual(set(capture), EXPECTED_CAPTURE_FIELDS)
            self.assertEqual(capture["schema_version"], "suite_capture.v1")
            self.assertEqual(capture["capture_kind"], "reminder.snapshot")
            self.assertEqual(capture["payload"], {
                "reminder": reminder,
                "tags": ["project", "follow up"],
            })
            self.assertTrue(CANDIDATE_FIELDS.isdisjoint(capture))
            self.assertFalse((Path(temporary) / "candidates/queue.json").exists())

    def test_boring_news_reader_emits_exact_preferences_row_without_interpreting_topics(self) -> None:
        preferences = {
            "interest_topics": '["AI", "architecture"]',
            "blocked_topics": '["manufactured drama"]',
            "tone": "calm",
        }
        now = dt.datetime(2026, 7, 11, 19, 0, tzinfo=dt.timezone.utc)
        with tempfile.TemporaryDirectory() as temporary:
            inbox = Path(temporary) / "Harness Captures/Pending"
            with patch.object(
                ingest_boring_news,
                "execute_select",
                return_value=[preferences],
            ):
                result = ingest_boring_news.run(inbox, now=now)

            self.assertEqual(result["captures_emitted"], 1)
            files = list(inbox.glob("*.json"))
            self.assertEqual(len(files), 1)
            capture = json.loads(files[0].read_text())
            self.assertEqual(set(capture), EXPECTED_CAPTURE_FIELDS)
            self.assertEqual(capture["capture_kind"], "preferences.snapshot")
            self.assertEqual(capture["payload"], {"preferences": preferences})
            self.assertTrue(CANDIDATE_FIELDS.isdisjoint(capture))
            self.assertFalse((Path(temporary) / "candidates/queue.json").exists())

    def test_dry_run_reports_capture_without_writing_it(self) -> None:
        reminder = {
            "id": "reminder-dry",
            "created_at": "2026-07-11T18:00:00Z",
        }
        with tempfile.TemporaryDirectory() as temporary:
            inbox = Path(temporary) / "Pending"
            with patch.object(ingest_recall, "fetch_reminders", return_value=[reminder]), patch.object(
                ingest_recall,
                "fetch_tags",
                return_value={},
            ):
                result = ingest_recall.run(inbox, dry_run=True)

            self.assertEqual(result["captures_emitted"], 1)
            self.assertFalse(inbox.exists())


if __name__ == "__main__":
    unittest.main()
