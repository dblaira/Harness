#!/usr/bin/env python3
"""Read boring-news preferences and emit a neutral ``suite_capture.v1`` file.

The Aurora database remains read-only. This script transports the stored row;
it does not interpret interests, assign strength, or write a candidate.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import subprocess
import sys
from pathlib import Path

from suite_capture_output import build_suite_capture, utc_timestamp, write_suite_capture


CLUSTER_ARN = "arn:aws:rds:us-west-2:061890415918:cluster:boringnews-db5d02a0a9-d7uayrkzyjmu"
DATABASE = "boring"


def default_capture_inbox() -> Path:
    configured = os.environ.get("HARNESS_NEWS_CALM_CAPTURE_INBOX")
    if configured:
        return Path(configured).expanduser()
    return (
        Path.home()
        / "Library/Mobile Documents/iCloud~com~newscalm~app/Documents"
        / "Harness Captures/Pending"
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
    command = [
        "aws",
        "rds-data",
        "execute-statement",
        "--resource-arn",
        CLUSTER_ARN,
        "--secret-arn",
        secret_arn(),
        "--database",
        DATABASE,
        "--sql",
        sql,
        "--include-result-metadata",
        "--output",
        "json",
    ]
    completed = subprocess.run(command, capture_output=True, text=True, check=False)
    if completed.returncode != 0:
        raise SystemExit(f"boring-news Data API call failed: {completed.stderr.strip()}")
    response = json.loads(completed.stdout)
    columns = [column["name"] for column in response.get("columnMetadata", [])]
    rows = []
    for record in response.get("records", []):
        row = {}
        for column, cell in zip(columns, record):
            row[column] = next(iter(cell.values())) if cell and not cell.get("isNull") else None
        rows.append(row)
    return rows


def build_preferences_capture(
    preferences: dict,
    *,
    now: dt.datetime | None = None,
) -> dict:
    return build_suite_capture(
        source_slug="news-calm-preferences",
        source_app="boring-news",
        source_record_id="preferences-1",
        captured_at=utc_timestamp(now=now),
        capture_kind="preferences.snapshot",
        payload={"preferences": preferences},
    )


def run(
    capture_inbox: Path,
    dry_run: bool = False,
    *,
    now: dt.datetime | None = None,
) -> dict:
    rows = execute_select(
        "SELECT interest_topics, blocked_topics, tone FROM preferences WHERE id = 1"
    )
    deliveries = []
    if rows:
        capture = build_preferences_capture(rows[0], now=now)
        deliveries.append(write_suite_capture(capture, capture_inbox, dry_run=dry_run))
    return {
        "preferences_row_found": bool(rows),
        "captures_emitted": len(deliveries),
        "capture_ids": [delivery["capture_id"] for delivery in deliveries],
        "capture_inbox": str(capture_inbox),
        "dry_run": dry_run,
    }


def main() -> int:
    load_local_env()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--capture-inbox", type=Path, default=default_capture_inbox())
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    print(json.dumps(run(args.capture_inbox, dry_run=args.dry_run), indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
