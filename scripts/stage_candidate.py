#!/usr/bin/env python3
"""Validate and atomically stage one Harness review candidate.

This command writes only ``Ontology/candidates/queue.json``. It never touches
the accepted graph, either decision ledger, or Fuseki. The caller must stop the
running Harness app before a real write so an in-app decision cannot race the
atomic replacement.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


ALLOWED_DOMAINS = {
    "affect",
    "ambition",
    "belief",
    "entertainment",
    "exercise",
    "health",
    "insight",
    "learning",
    "nutrition",
    "purchase",
    "sleep",
    "social",
    "work",
}
REQUIRED_FIELDS = {
    "id",
    "status",
    "plain",
    "evidence",
    "source",
    "domain_a",
    "domain_b",
    "connection_type",
}
OPTIONAL_FIELDS = {"strength"}
PREFIXES = """@prefix understood: <https://understood.app/ontology#> .
@prefix xsd: <http://www.w3.org/2001/XMLSchema#> .

"""


class CandidateStageError(ValueError):
    """A candidate or queue failed a fail-closed staging check."""


def default_ontology_root() -> Path:
    return (
        Path.home()
        / "Library/Mobile Documents/com~apple~CloudDocs/Documents/Main/Ontology"
    )


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def require_text(candidate: dict[str, Any], field: str) -> str:
    value = candidate.get(field)
    if not isinstance(value, str) or not value.strip():
        raise CandidateStageError(f"{field} must be non-empty text")
    return value.strip()


def validate_candidate(candidate: Any) -> dict[str, Any]:
    if not isinstance(candidate, dict):
        raise CandidateStageError("candidate file must contain one JSON object")

    fields = set(candidate)
    missing = REQUIRED_FIELDS - fields
    unknown = fields - REQUIRED_FIELDS - OPTIONAL_FIELDS
    if missing:
        raise CandidateStageError(f"candidate is missing fields: {', '.join(sorted(missing))}")
    if unknown:
        raise CandidateStageError(f"candidate has unsupported fields: {', '.join(sorted(unknown))}")

    normalized = {field: candidate[field] for field in REQUIRED_FIELDS}
    candidate_id = require_text(candidate, "id")
    if not candidate_id.startswith("cand-"):
        raise CandidateStageError("id must start with cand-")
    if require_text(candidate, "status") != "pending":
        raise CandidateStageError("status must be pending")
    if not require_text(candidate, "plain").startswith("AGENT PROPOSAL:"):
        raise CandidateStageError("plain must start with AGENT PROPOSAL:")
    require_text(candidate, "evidence")
    require_text(candidate, "source")
    require_text(candidate, "connection_type")

    for field in ("domain_a", "domain_b"):
        domain = require_text(candidate, field).lower()
        if domain not in ALLOWED_DOMAINS:
            raise CandidateStageError(f"{field} is not an allowed life domain")
        normalized[field] = domain

    if "strength" in candidate:
        strength = candidate["strength"]
        if isinstance(strength, bool) or not isinstance(strength, (int, float)):
            raise CandidateStageError("strength must be a number between 0 and 1")
        if not 0 <= float(strength) <= 1:
            raise CandidateStageError("strength must be a number between 0 and 1")
        normalized["strength"] = float(strength)

    for field in ("id", "status", "plain", "evidence", "source", "connection_type"):
        normalized[field] = require_text(candidate, field)
    return normalized


def escape_literal(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def candidate_turtle(candidate: dict[str, Any]) -> str:
    connection_id = candidate["id"].replace("cand-", "conn-obs-", 1)
    accepted_at = dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")
    lines = [
        PREFIXES,
        f"<https://understood.app/ontology/connection/{connection_id}> a understood:Connection ;",
        f'  understood:label "{escape_literal(candidate["plain"].rstrip("."))}" ;',
        f'  understood:connectionType "{escape_literal(candidate["connection_type"])}" ;',
        f"  understood:inLifeDomain <https://understood.app/ontology/domain/{candidate['domain_a']}> ;",
        f"  understood:inLifeDomain <https://understood.app/ontology/domain/{candidate['domain_b']}> ;",
    ]
    if "strength" in candidate:
        lines.append(f'  understood:strength "{candidate["strength"]:.2f}"^^xsd:decimal ;')
    lines.extend(
        [
            '  understood:frequency "usually" ;',
            f'  understood:evidenceNote "{escape_literal(candidate["evidence"])}" ;',
            f'  understood:acceptedAt "{accepted_at}"^^xsd:dateTime ;',
            "  .",
            "",
        ]
    )
    return "\n".join(lines)


def validate_shacl(candidate: dict[str, Any], repository_root: Path) -> None:
    validator = repository_root / "scripts/validate_connection_turtle.py"
    if not validator.is_file():
        raise CandidateStageError("SHACL validator script was not found")
    completed = subprocess.run(
        [sys.executable, str(validator), "--json"],
        input=candidate_turtle(candidate),
        text=True,
        capture_output=True,
        check=False,
    )
    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise CandidateStageError(
            completed.stderr.strip() or "SHACL validator returned unreadable output"
        ) from error
    if completed.returncode != 0 or not payload.get("conforms"):
        messages = payload.get("messages") or ["candidate does not match the connection grammar"]
        raise CandidateStageError("SHACL blocked candidate: " + "; ".join(messages))


def load_queue(queue_path: Path) -> tuple[list[dict[str, Any]], bytes]:
    if not queue_path.is_file():
        raise CandidateStageError(f"queue file does not exist: {queue_path}")
    original = queue_path.read_bytes()
    try:
        queue = json.loads(original)
    except json.JSONDecodeError as error:
        raise CandidateStageError("queue.json is not valid JSON") from error
    if not isinstance(queue, list) or not all(isinstance(entry, dict) for entry in queue):
        raise CandidateStageError("queue.json must be an array of objects")
    return queue, original


def stage_candidate(
    candidate: dict[str, Any],
    ontology_root: Path,
    repository_root: Path,
    *,
    dry_run: bool = False,
    expected_queue_sha: str | None = None,
    max_existing_pending: int = 0,
) -> dict[str, Any]:
    candidate = validate_candidate(candidate)
    validate_shacl(candidate, repository_root)

    queue_path = ontology_root / "candidates/queue.json"
    queue, original = load_queue(queue_path)
    before_sha = sha256(original)
    if expected_queue_sha and before_sha != expected_queue_sha:
        raise CandidateStageError("queue changed since the caller recorded its baseline")

    existing = next((entry for entry in queue if entry.get("id") == candidate["id"]), None)
    if existing is not None:
        if existing == candidate:
            return {
                "candidate_id": candidate["id"],
                "outcome": "already-present",
                "queue_path": str(queue_path),
                "queue_sha": before_sha,
                "pending_before": sum(entry.get("status") == "pending" for entry in queue),
                "shacl": "passed",
            }
        raise CandidateStageError("candidate id already exists with different content")

    pending_before = sum(entry.get("status") == "pending" for entry in queue)
    if pending_before > max_existing_pending:
        raise CandidateStageError(
            f"queue already has {pending_before} pending candidate(s); refusing to add another"
        )

    updated = [*queue, candidate]
    encoded = (json.dumps(updated, indent=2, sort_keys=True) + "\n").encode()
    if dry_run:
        return {
            "candidate_id": candidate["id"],
            "outcome": "validated-dry-run",
            "queue_path": str(queue_path),
            "queue_sha": before_sha,
            "pending_before": pending_before,
            "pending_after": pending_before + 1,
            "shacl": "passed",
        }

    if queue_path.read_bytes() != original:
        raise CandidateStageError("queue changed during staging; nothing was written")

    queue_path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary_name = tempfile.mkstemp(prefix="queue.", suffix=".json", dir=queue_path.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_name, queue_path)
    finally:
        if os.path.exists(temporary_name):
            os.unlink(temporary_name)

    return {
        "candidate_id": candidate["id"],
        "outcome": "staged",
        "queue_path": str(queue_path),
        "before_sha": before_sha,
        "after_sha": sha256(queue_path.read_bytes()),
        "pending_before": pending_before,
        "pending_after": pending_before + 1,
        "shacl": "passed",
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--ontology-root", type=Path, default=default_ontology_root())
    parser.add_argument("--repository-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--expected-queue-sha")
    parser.add_argument("--max-existing-pending", type=int, default=0)
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        candidate = json.loads(args.candidate.read_text())
        result = stage_candidate(
            candidate,
            args.ontology_root,
            args.repository_root,
            dry_run=args.dry_run,
            expected_queue_sha=args.expected_queue_sha,
            max_existing_pending=args.max_existing_pending,
        )
    except (OSError, json.JSONDecodeError, CandidateStageError) as error:
        print(json.dumps({"error": str(error), "written": False}, indent=2), file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
