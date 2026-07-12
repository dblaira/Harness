#!/usr/bin/env python3
"""Read Re_Call records and emit neutral ``suite_capture.v1`` files.

Re_Call's database remains read-only here. This transport records each
reminder and its tags without deciding whether it is a Harness candidate.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections import defaultdict
from pathlib import Path

from suite_capture_output import build_suite_capture, utc_timestamp, write_suite_capture


RECALL_SUPABASE_URL = "https://vzaceoipwimphdvdxcpa.supabase.co"


def default_capture_inbox() -> Path:
    configured = os.environ.get("HARNESS_RECALL_CAPTURE_INBOX")
    if configured:
        return Path(configured).expanduser()
    return (
        Path.home()
        / "Library/Mobile Documents/iCloud~app~understood~recall/Documents"
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


def recall_headers() -> dict[str, str]:
    key = os.environ.get("RECALL_SERVICE_ROLE_KEY") or os.environ.get("RECALL_JWT")
    if not key:
        raise SystemExit(
            "BLOCKED: no RECALL_SERVICE_ROLE_KEY or RECALL_JWT in local .env.\n"
            "Re_Call's own .env only has an anon publishable key, which cannot read the "
            "`recall` schema (confirmed: 'permission denied for schema recall').\n"
            "This script is otherwise ready to run - it needs Adam to hand over one of "
            "those two credentials for https://vzaceoipwimphdvdxcpa.supabase.co."
        )
    apikey = os.environ.get(
        "RECALL_PUBLISHABLE_KEY", "sb_publishable_S-wJBLUZqp7ad2D_JpT0xQ_yCTHEnpX"
    )
    return {
        "apikey": apikey,
        "Authorization": f"Bearer {key}",
        "Accept-Profile": "recall",
        "Accept": "application/json",
    }


def rest_get(path: str, query: dict[str, str], offset: int, limit: int) -> list[dict]:
    if query.get("select") is None:
        raise SystemExit("Refusing to run: recall ingest only permits select reads.")
    query_string = urllib.parse.urlencode(query, safe="(),.*")
    url = f"{RECALL_SUPABASE_URL}/rest/v1/{path}?{query_string}"
    request = urllib.request.Request(
        url,
        headers={
            **recall_headers(),
            "Range-Unit": "items",
            "Range": f"{offset}-{offset + limit - 1}",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", errors="replace")
        raise SystemExit(f"Re_Call read failed ({error.code}): {body}") from error


def fetch_reminders() -> list[dict]:
    rows: list[dict] = []
    offset = 0
    page_size = 1000
    while True:
        page = rest_get(
            "reminders",
            {
                "select": "id,kind,status,list_name,due_date,created_at",
                "order": "created_at.asc",
            },
            offset=offset,
            limit=page_size,
        )
        rows.extend(page)
        if len(page) < page_size:
            break
        offset += page_size
    return rows


def fetch_tags() -> dict[str, list[str]]:
    rows: list[dict] = []
    offset = 0
    while True:
        page = rest_get(
            "reminder_tags",
            {"select": "reminder_id,tag"},
            offset=offset,
            limit=1000,
        )
        rows.extend(page)
        if len(page) < 1000:
            break
        offset += 1000
    by_reminder: dict[str, list[str]] = defaultdict(list)
    for row in rows:
        reminder_id = row.get("reminder_id")
        tag = row.get("tag")
        if isinstance(reminder_id, str) and isinstance(tag, str):
            by_reminder[reminder_id].append(tag)
    return dict(by_reminder)


def build_reminder_capture(
    reminder: dict,
    tags: list[str],
    *,
    now: dt.datetime | None = None,
) -> dict:
    source_record_id = str(reminder.get("id") or "").strip()
    if not source_record_id:
        raise ValueError("Re_Call reminder is missing its durable id")
    return build_suite_capture(
        source_slug="recall-reminder",
        source_app="Re_Call",
        source_record_id=source_record_id,
        captured_at=utc_timestamp(reminder.get("created_at"), now=now),
        capture_kind="reminder.snapshot",
        payload={"reminder": reminder, "tags": tags},
    )


def run(
    capture_inbox: Path,
    dry_run: bool = False,
    *,
    now: dt.datetime | None = None,
) -> dict:
    reminders = fetch_reminders()
    tags_by_reminder = fetch_tags()
    deliveries = []
    for reminder in reminders:
        reminder_id = str(reminder.get("id") or "")
        capture = build_reminder_capture(
            reminder,
            tags_by_reminder.get(reminder_id, []),
            now=now,
        )
        deliveries.append(
            write_suite_capture(capture, capture_inbox, dry_run=dry_run)
        )
    return {
        "reminders_fetched": len(reminders),
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
