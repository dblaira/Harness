#!/usr/bin/env python3
"""Log an Adam-confirmed UnpromptedSignal event into accepted graph authority."""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_ONTOLOGY_ROOT = (
    Path.home()
    / "Library/Mobile Documents/com~apple~CloudDocs/Documents/Main/Ontology"
)
DEFAULT_FUSEKI_DATA_ENDPOINT = "http://127.0.0.1:3030/understood/data"
ACCEPTED_GRAPH_IRI = "https://understood.app/graph/accepted"
VALIDATOR = ROOT / "scripts/validate_connection_turtle.py"

PREFIXES = """@prefix understood: <https://understood.app/ontology#> .
@prefix xsd: <http://www.w3.org/2001/XMLSchema#> .

"""


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def escape_literal(text: str) -> str:
    return (
        text.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .strip()
    )


def event_turtle(event_id: str, occurred_at: str, who: str, what: str, logged_by: str) -> str:
    return f"""{PREFIXES}<https://understood.app/ontology/signal/{event_id}> a understood:UnpromptedSignal ;
  understood:occurredAt "{escape_literal(occurred_at)}"^^xsd:dateTime ;
  understood:whoSaid "{escape_literal(who)}" ;
  understood:whatTheySaid "{escape_literal(what)}" ;
  understood:loggedBy "{escape_literal(logged_by)}" ;
  .

"""


def validator_python() -> str:
    candidates = [
        ROOT / ".venv/bin/python",
        ROOT / ".venv/bin/python3",
    ]
    for candidate in candidates:
        if candidate.exists() and os.access(candidate, os.X_OK):
            return str(candidate)
    return sys.executable


def validate_turtle(turtle: str) -> None:
    if not VALIDATOR.exists():
        raise RuntimeError(f"SHACL validator not found: {VALIDATOR}")
    with tempfile.NamedTemporaryFile("w", suffix=".ttl", delete=False) as handle:
        handle.write(turtle)
        temp_path = Path(handle.name)
    try:
        completed = subprocess.run(
            [validator_python(), str(VALIDATOR), "--json", str(temp_path)],
            check=False,
            text=True,
            capture_output=True,
        )
    finally:
        temp_path.unlink(missing_ok=True)
    if completed.returncode != 0:
        try:
            payload = json.loads(completed.stdout)
            messages = "; ".join(payload.get("messages") or [])
        except json.JSONDecodeError:
            messages = completed.stderr.strip() or completed.stdout.strip()
        raise RuntimeError(f"SHACL blocked signal event: {messages}")


def append_to_accepted_graph(ontology_root: Path, turtle: str) -> Path:
    accepted_graph = ontology_root / "accepted" / "accepted-graph.ttl"
    accepted_graph.parent.mkdir(parents=True, exist_ok=True)
    if not accepted_graph.exists():
        accepted_graph.write_text("# Accepted graph - claims approved by Adam.\n\n" + PREFIXES)
    with accepted_graph.open("a") as handle:
        handle.write("\n")
        handle.write(turtle)
    return accepted_graph


def post_to_fuseki(turtle: str, endpoint: str) -> bool:
    url = endpoint + "?" + urllib.parse.urlencode({"graph": ACCEPTED_GRAPH_IRI})
    request = urllib.request.Request(
        url,
        data=turtle.encode("utf-8"),
        method="POST",
        headers={"Content-Type": "text/turtle"},
    )
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            return 200 <= response.status < 300
    except Exception as exc:
        print(f"Fuseki accepted graph sync skipped: {exc}", file=sys.stderr)
        return False


def ledger_path() -> Path:
    return Path.home() / "Library/Application Support/Harness/harness-ledger.sqlite"


def record_ledger_event(
    event_id: str,
    occurred_at: str,
    who: str,
    what: str,
    logged_by: str,
    path: Path | None = None,
) -> None:
    path = path or ledger_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(path) as db:
        db.execute(
            """
            CREATE TABLE IF NOT EXISTS unprompted_signal_events (
              id TEXT PRIMARY KEY,
              occurredAt TEXT NOT NULL,
              whoSaid TEXT NOT NULL,
              whatTheySaid TEXT NOT NULL,
              loggedBy TEXT NOT NULL,
              createdAt TEXT NOT NULL
            )
            """
        )
        db.execute(
            """
            INSERT OR REPLACE INTO unprompted_signal_events
            (id, occurredAt, whoSaid, whatTheySaid, loggedBy, createdAt)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (event_id, occurred_at, who, what, logged_by, utc_now()),
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Log an unprompted Clear Sign event.")
    parser.add_argument("who", help="First name only.")
    parser.add_argument("what", help="Short paraphrase of what they said.")
    parser.add_argument("--occurred-at", default=utc_now(), help="ISO date-time; defaults to now.")
    parser.add_argument("--logged-by", default="Adam")
    parser.add_argument("--ontology-root", type=Path, default=DEFAULT_ONTOLOGY_ROOT)
    parser.add_argument(
        "--fuseki-data-endpoint",
        default=os.environ.get("HARNESS_FUSEKI_DATA_ENDPOINT", DEFAULT_FUSEKI_DATA_ENDPOINT),
    )
    parser.add_argument("--ledger-path", type=Path, default=None)
    parser.add_argument("--no-fuseki", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not args.who.strip() or any(ch.isspace() for ch in args.who.strip()):
        print("who must be a first name only", file=sys.stderr)
        return 2
    if not args.what.strip():
        print("what must be a short paraphrase", file=sys.stderr)
        return 2

    event_id = f"unprompted-signal-{datetime.now(timezone.utc).strftime('%Y%m%d%H%M%S')}-{uuid.uuid4().hex[:8]}"
    turtle = event_turtle(event_id, args.occurred_at, args.who.strip(), args.what.strip(), args.logged_by.strip())
    validate_turtle(turtle)
    accepted_graph = append_to_accepted_graph(args.ontology_root, turtle)
    fuseki_synced = False if args.no_fuseki else post_to_fuseki(turtle, args.fuseki_data_endpoint)
    record_ledger_event(event_id, args.occurred_at, args.who.strip(), args.what.strip(), args.logged_by.strip(), args.ledger_path)
    print(f"Logged {event_id}")
    print(f"Accepted graph: {accepted_graph}")
    print(f"Fuseki /accepted sync: {'ok' if fuseki_synced else 'skipped'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
