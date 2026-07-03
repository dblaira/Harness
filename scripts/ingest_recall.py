#!/usr/bin/env python3
"""Read Re_Call evidence and append review-queue candidates.

Re_Call is a separate Supabase project from Understood/Harness's own
(https://vzaceoipwimphdvdxcpa.supabase.co, schema `recall`). This script
follows the same authority-safe contract as ingest_evidence.py:

- Supabase access is read-only (GET + select only, enforced below).
- Accepted graph files are never edited.
- New claims are appended only to Ontology/candidates/queue.json.

Credential note: Re_Call's own .env only carries an anon publishable key,
which cannot read the `recall` schema (PostgREST returns
`permission denied for schema recall`, confirmed 2026-07-02). This script
needs one of RECALL_SERVICE_ROLE_KEY or RECALL_JWT set in a local .env
before it can do anything beyond report that it's blocked.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter, defaultdict
from pathlib import Path

RECALL_SUPABASE_URL = "https://vzaceoipwimphdvdxcpa.supabase.co"
MAX_NEW_CANDIDATES = 10
DEFAULT_START_DATE = dt.date(2024, 6, 1)

# Freeform Re_Call tags -> life domains. Extend as real tag vocabulary is seen.
DOMAIN_KEYWORDS = {
    "exercise": r"(?i)\b(run|workout|gym|training|exercise|stretch|mobility)\b",
    "nutrition": r"(?i)\b(food|meal|protein|diet|nutrition|supplement|grocery)\b",
    "health": r"(?i)\b(health|sleep|doctor|injury|recovery|medical)\b",
    "work": r"(?i)\b(work|project|build|code|meeting|deploy|ship)\b",
    "ambition": r"(?i)\b(goal|business|founder|strategy|growth)\b",
    "social": r"(?i)\b(stephanie|family|friend|gym buddy|call|text)\b",
    "purchase": r"(?i)\b(buy|order|purchase|shop|amazon)\b",
    "learning": r"(?i)\b(read|learn|book|course|study|research)\b",
    "belief": r"(?i)\b(pattern|leverage|principle|philosophy)\b",
    "insight": r"(?i)\b(idea|reflect|insight|realize)\b",
}


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
    apikey = os.environ.get("RECALL_PUBLISHABLE_KEY", "sb_publishable_S-wJBLUZqp7ad2D_JpT0xQ_yCTHEnpX")
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
        headers={**recall_headers(), "Range-Unit": "items", "Range": f"{offset}-{offset + limit - 1}"},
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
            {"select": "id,kind,status,list_name,due_date,created_at", "order": "created_at.asc"},
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
        page = rest_get("reminder_tags", {"select": "reminder_id,tag"}, offset=offset, limit=1000)
        rows.extend(page)
        if len(page) < 1000:
            break
        offset += 1000
    by_reminder: dict[str, list[str]] = defaultdict(list)
    for row in rows:
        by_reminder[row["reminder_id"]].append(row["tag"])
    return by_reminder


def domain_for_tag(tag: str) -> str | None:
    for domain, pattern in DOMAIN_KEYWORDS.items():
        if re.search(pattern, tag):
            return domain
    return None


def load_queue(queue_path: Path) -> list[dict]:
    if not queue_path.exists():
        return []
    return json.loads(queue_path.read_text())


def save_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def build_kind_practice_card(kind_counts: Counter, run_date: str) -> dict | None:
    total = sum(kind_counts.values())
    if total < 10:
        return None
    action_share = kind_counts.get("action", 0) / total
    if action_share < 0.15:
        return None
    return {
        "id": f"cand-recall-{run_date}-ambition-work-action-tracking",
        "status": "pending",
        "plain": (
            f"Adam tracks not just reminders but outcomes: {round(action_share * 100)}% of his "
            "Re_Call entries are logged as actions (with effort/energy/outcome), not plain reminders."
        ),
        "evidence": (
            f"{kind_counts.get('action', 0)} of {total} Re_Call entries are kind='action' "
            f"(vs. {kind_counts.get('reminder', 0)} plain reminders, {kind_counts.get('event', 0)} events). "
            "Unreviewed extraction from Re_Call Supabase."
        ),
        "source": f"recall-ingest {run_date}",
        "domain_a": "ambition",
        "domain_b": "work",
        "strength": round(min(action_share * 2, 0.85), 2),
        "connection_type": "observed_practice",
    }


def run(ontology_root: Path, dry_run: bool = False) -> dict:
    run_date = dt.date.today().isoformat()
    candidates_dir = ontology_root / "candidates"
    queue_path = candidates_dir / "queue.json"
    ingest_log_path = candidates_dir / "ingest-log.json"

    reminders = fetch_reminders()
    tags_by_reminder = fetch_tags()

    kind_counts = Counter(r.get("kind", "reminder") for r in reminders)
    domain_hits = Counter()
    for reminder in reminders:
        for tag in tags_by_reminder.get(reminder["id"], []):
            domain = domain_for_tag(tag)
            if domain:
                domain_hits[domain] += 1

    queue = load_queue(queue_path)
    existing_ids = {c["id"] for c in queue}
    new_cards = []

    card = build_kind_practice_card(kind_counts, run_date)
    if card and card["id"] not in existing_ids:
        new_cards.append(card)

    new_cards = new_cards[:MAX_NEW_CANDIDATES]

    result = {
        "run_date": run_date,
        "reminders_fetched": len(reminders),
        "kind_counts": dict(kind_counts),
        "tag_domain_hits": dict(domain_hits),
        "candidates_created": len(new_cards),
        "dry_run": dry_run,
    }

    if not dry_run and new_cards:
        queue.extend(new_cards)
        save_json(queue_path, queue)
        log = json.loads(ingest_log_path.read_text()) if ingest_log_path.exists() else []
        log.append({
            "run_date": run_date,
            "source": "recall-ingest",
            "cards_queued": len(new_cards),
            "card_ids": [c["id"] for c in new_cards],
        })
        save_json(ingest_log_path, log)

    return result


if __name__ == "__main__":
    load_local_env()
    dry = "--dry-run" in sys.argv
    print(json.dumps(run(default_ontology_root(), dry_run=dry), indent=2))
