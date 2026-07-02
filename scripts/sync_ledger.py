#!/usr/bin/env python3
"""Unify the two decision ledgers into the canonical JSON ledger.

Harness has two places where review decisions land:
  1. The macOS app writes to SQLite: ~/Library/Application Support/Harness/
     harness-ledger.sqlite, table review_queue_decisions.
  2. CLI scripts (review_queue.py, log_signal.py) append to the canonical
     JSON ledger: Ontology/accepted/decision-ledger.json in iCloud.

This script makes the JSON ledger the union: it mirrors any app (SQLite)
decision that is not yet in the JSON ledger. It is:
  - read-only against SQLite (opened with mode=ro),
  - append-only against the JSON ledger (never edits or removes entries),
  - idempotent (dedupes on the app's row id, carried as app_ledger_id).

Run it after a review session in the app, or on a schedule. A --dry-run
flag reports what would sync without writing.
"""

from __future__ import annotations

import argparse
import json
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

APP_LEDGER = (
    Path.home() / "Library/Application Support/Harness/harness-ledger.sqlite"
)
CANONICAL_LEDGER = (
    Path.home()
    / "Library/Mobile Documents/com~apple~CloudDocs/Documents/Main/Ontology"
    / "accepted/decision-ledger.json"
)


def read_app_decisions(db_path: Path) -> list[dict]:
    uri = f"file:{db_path}?mode=ro"
    with sqlite3.connect(uri, uri=True) as conn:
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            "SELECT id, claimId, decision, frequency, claim, evidenceNote, "
            "sourceRef, createdAt FROM review_queue_decisions ORDER BY createdAt"
        ).fetchall()
    decisions = []
    for row in rows:
        at = datetime.fromtimestamp(row["createdAt"], tz=timezone.utc).isoformat()
        entry = {
            "ledger_id": row["id"][:8],
            "app_ledger_id": row["id"],
            "claim_id": row["claimId"],
            "decision": row["decision"],
            "claim": row["claim"],
            "at": at,
            "source": "harness-app",
        }
        if row["frequency"]:
            entry["frequency"] = row["frequency"]
        decisions.append(entry)
    return decisions


def sync(dry_run: bool) -> dict:
    if not APP_LEDGER.exists():
        raise SystemExit(f"App ledger not found: {APP_LEDGER}")
    if not CANONICAL_LEDGER.exists():
        raise SystemExit(f"Canonical ledger not found: {CANONICAL_LEDGER}")

    ledger = json.loads(CANONICAL_LEDGER.read_text())
    already_synced = {e.get("app_ledger_id") for e in ledger if e.get("app_ledger_id")}
    # Safety net: never duplicate a decision the JSON ledger already records,
    # even if it lacks an app_ledger_id (e.g. a CLI decision on the same claim
    # at the same second).
    existing_keys = {
        (e.get("claim_id"), e.get("decision"), (e.get("at") or "")[:19])
        for e in ledger
    }

    new_entries = []
    for entry in read_app_decisions(APP_LEDGER):
        if entry["app_ledger_id"] in already_synced:
            continue
        key = (entry["claim_id"], entry["decision"], entry["at"][:19])
        if key in existing_keys:
            continue
        new_entries.append(entry)

    if new_entries and not dry_run:
        ledger.extend(new_entries)
        CANONICAL_LEDGER.write_text(json.dumps(ledger, indent=2) + "\n")

    return {
        "app_decisions": len(read_app_decisions(APP_LEDGER)),
        "canonical_entries_before": len(ledger) - (0 if dry_run else len(new_entries)),
        "synced_now": len(new_entries),
        "canonical_entries_after": len(ledger) if not dry_run else None,
        "dry_run": dry_run,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    result = sync(args.dry_run)
    json.dump(result, sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main()
