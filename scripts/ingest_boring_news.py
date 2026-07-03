#!/usr/bin/env python3
"""Read boring-news evidence and append review-queue candidates.

boring-news runs on AWS Aurora PostgreSQL, queried read-only through the
RDS Data API (no direct DB connection needed). Same authority-safe
contract as ingest_evidence.py and ingest_recall.py:

- Only SELECT statements are ever sent (enforced below).
- Accepted graph files are never edited.
- New claims are appended only to Ontology/candidates/queue.json.

Credential note: the cluster is known
(arn:aws:rds:us-west-2:061890415918:cluster:boringnews-db5d02a0a9-d7uayrkzyjmu,
database "boring") but the Data API also needs a Secrets Manager secret
ARN holding the DB credentials. The local AWS ops user
(blair.ai.ops) is denied secretsmanager:ListSecrets, so this script needs
BORING_NEWS_SECRET_ARN set in a local .env - either Adam hands over the
ARN, or grants this IAM user secretsmanager:GetSecretValue scoped to it.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import subprocess
import sys
from pathlib import Path

CLUSTER_ARN = "arn:aws:rds:us-west-2:061890415918:cluster:boringnews-db5d02a0a9-d7uayrkzyjmu"
DATABASE = "boring"
MAX_NEW_CANDIDATES = 10


def default_ontology_root() -> Path:
    return (
        Path.home()
        / "Library/Mobile Documents/com~apple~CloudDocs/Documents/Main/Ontology"
    )


def load_env_file(path: Path) -> None:
    if not path.exists():
        return
    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


def load_local_env() -> None:
    for path in [Path.cwd() / ".env", Path.home() / "Developer/GitHub/Harness/.env"]:
        load_env_file(path)


def secret_arn() -> str:
    arn = os.environ.get("BORING_NEWS_SECRET_ARN")
    if not arn:
        raise SystemExit(
            "BLOCKED: no BORING_NEWS_SECRET_ARN in local .env.\n"
            "This IAM user (blair.ai.ops) cannot list Secrets Manager secrets, so the "
            "Data API credential secret can't be discovered automatically.\n"
            "This script is otherwise ready to run - it needs Adam to either hand over "
            "the secret ARN, or grant secretsmanager:GetSecretValue scoped to it."
        )
    return arn


def execute_select(sql: str) -> list[dict]:
    if not sql.strip().upper().startswith("SELECT"):
        raise SystemExit("Refusing to run: boring-news ingest only permits SELECT statements.")
    cmd = [
        "aws", "rds-data", "execute-statement",
        "--resource-arn", CLUSTER_ARN,
        "--secret-arn", secret_arn(),
        "--database", DATABASE,
        "--sql", sql,
        "--include-result-metadata",
        "--output", "json",
    ]
    completed = subprocess.run(cmd, capture_output=True, text=True)
    if completed.returncode != 0:
        raise SystemExit(f"boring-news Data API call failed: {completed.stderr.strip()}")
    payload = json.loads(completed.stdout)
    columns = [c["name"] for c in payload.get("columnMetadata", [])]
    rows = []
    for record in payload.get("records", []):
        row = {}
        for col, cell in zip(columns, record):
            value = next(iter(cell.values())) if cell and not cell.get("isNull") else None
            row[col] = value
        rows.append(row)
    return rows


def build_preferences_card(prefs: dict, run_date: str) -> dict | None:
    topics = prefs.get("interest_topics")
    if not topics:
        return None
    try:
        topics_list = json.loads(topics) if isinstance(topics, str) else topics
    except (TypeError, ValueError):
        return None
    if not topics_list:
        return None
    return {
        "id": f"cand-boringnews-{run_date}-learning-work-stated-interests",
        "status": "pending",
        "plain": f"Adam has told his news app to prioritize: {', '.join(topics_list[:6])}.",
        "evidence": (
            f"boring-news preferences.interest_topics: {json.dumps(topics_list)}. "
            "Unreviewed extraction from boring-news Aurora database."
        ),
        "source": f"boringnews-ingest {run_date}",
        "domain_a": "learning",
        "domain_b": "work",
        "strength": 0.7,
        "connection_type": "stated_preference",
    }


def load_queue(queue_path: Path) -> list[dict]:
    if not queue_path.exists():
        return []
    return json.loads(queue_path.read_text())


def save_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def run(ontology_root: Path, dry_run: bool = False) -> dict:
    run_date = dt.date.today().isoformat()
    candidates_dir = ontology_root / "candidates"
    queue_path = candidates_dir / "queue.json"
    ingest_log_path = candidates_dir / "ingest-log.json"

    rows = execute_select("SELECT interest_topics, blocked_topics, tone FROM preferences WHERE id = 1")
    prefs = rows[0] if rows else {}

    queue = load_queue(queue_path)
    existing_ids = {c["id"] for c in queue}
    new_cards = []
    card = build_preferences_card(prefs, run_date)
    if card and card["id"] not in existing_ids:
        new_cards.append(card)
    new_cards = new_cards[:MAX_NEW_CANDIDATES]

    result = {
        "run_date": run_date,
        "preferences_row_found": bool(rows),
        "candidates_created": len(new_cards),
        "dry_run": dry_run,
    }

    if not dry_run and new_cards:
        queue.extend(new_cards)
        save_json(queue_path, queue)
        log = json.loads(ingest_log_path.read_text()) if ingest_log_path.exists() else []
        log.append({
            "run_date": run_date,
            "source": "boringnews-ingest",
            "cards_queued": len(new_cards),
            "card_ids": [c["id"] for c in new_cards],
        })
        save_json(ingest_log_path, log)

    return result


if __name__ == "__main__":
    load_local_env()
    dry = "--dry-run" in sys.argv
    print(json.dumps(run(default_ontology_root(), dry_run=dry), indent=2))
