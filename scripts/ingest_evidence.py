#!/usr/bin/env python3
"""Read Supabase evidence and append review-queue candidates.

This script is intentionally authority-safe:
- Supabase access is read-only.
- Accepted graph files are never edited.
- New claims are appended only to Ontology/candidates/queue.json.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import os
import re
import statistics
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections import defaultdict
from pathlib import Path

SUPABASE_PROJECT_URL = "https://wqdacfrzurhpsiuvzxwo.supabase.co"
MAX_NEW_CANDIDATES = 10
OBSERVED = "observed_correlation"
WEAKENING = "weakening_review"
DEFAULT_START_DATE = dt.date(2024, 6, 1)
ACCEPTED_CORRELATION_METRIC = "binary_above_median_week_phi"
MIN_WEAKENING_BASELINE = 0.55
MAX_WEAKENING_CURRENT = 0.50


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
    candidates = [
        Path.cwd() / ".env",
        Path.home() / "Developer/GitHub/Harness/.env",
        Path.home() / "Developer/GitHub/obsidian-vault/.env",
    ]
    for path in candidates:
        load_env_file(path)


def supabase_headers() -> dict[str, str]:
    secret_key = os.environ.get("SUPABASE_SECRET_KEY", "")
    if not secret_key:
        raise SystemExit("SUPABASE_SECRET_KEY is missing from local .env.")
    return {
        "apikey": secret_key,
        "Accept": "application/json",
    }


def assert_read_only_request(method: str, query: dict[str, str]) -> None:
    if method.upper() != "GET":
        raise SystemExit("Refusing to run: Supabase ingest is read-only.")
    select = query.get("select")
    if not select:
        raise SystemExit("Refusing to run: Supabase ingest only permits select reads.")
    forbidden = {"insert", "update", "upsert", "delete", "rpc"}
    if any(key.lower() in forbidden for key in query):
        raise SystemExit("Refusing to run: Supabase ingest only permits select reads.")


def rest_get(path: str, query: dict[str, str], offset: int, limit: int) -> list[dict]:
    assert_read_only_request("GET", query)
    base_url = os.environ.get("SUPABASE_URL") or SUPABASE_PROJECT_URL
    query_string = urllib.parse.urlencode(query, safe="(),.*")
    url = f"{base_url.rstrip('/')}/rest/v1/{path}?{query_string}"
    request = urllib.request.Request(
        url,
        headers={
            **supabase_headers(),
            "Range-Unit": "items",
            "Range": f"{offset}-{offset + limit - 1}",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", errors="replace")
        raise SystemExit(f"Supabase read failed ({error.code}): {body}") from error


def fetch_extractions() -> list[dict]:
    rows: list[dict] = []
    page_size = 1000
    offset = 0
    query = {
        "select": "id,category,parent_category,time_window_start,time_window_end,created_at",
        "order": "time_window_start.asc.nullslast,created_at.asc",
    }
    while True:
        page = rest_get("extractions", query, offset=offset, limit=page_size)
        rows.extend(page)
        if len(page) < page_size:
            break
        offset += page_size
    if not rows:
        raise SystemExit(
            "Supabase returned zero extraction rows. RLS is enabled; use an Adam user "
            "JWT in SUPABASE_ACCESS_TOKEN or SUPABASE_JWT along with SUPABASE_PUBLISHABLE_KEY."
        )
    return rows


def parse_date(value: str | None) -> dt.date | None:
    if not value:
        return None
    try:
        return dt.date.fromisoformat(value[:10])
    except ValueError:
        return None


def parse_cli_date(value: str) -> dt.date:
    parsed = parse_date(value)
    if not parsed:
        raise argparse.ArgumentTypeError("expected YYYY-MM-DD")
    return parsed


def week_key(value: str | None) -> tuple[int, int] | None:
    parsed = parse_date(value)
    if not parsed:
        return None
    iso = parsed.isocalendar()
    return iso.year, iso.week


def row_event_date(row: dict) -> dt.date | None:
    return parse_date(row.get("time_window_start") or row.get("created_at"))


def filter_rows_by_date_window(
    rows: list[dict],
    start_date: dt.date,
    end_date: dt.date,
) -> list[dict]:
    return [
        row
        for row in rows
        if (event_date := row_event_date(row)) and start_date <= event_date <= end_date
    ]


def week_start(week: tuple[int, int]) -> dt.date:
    return dt.date.fromisocalendar(week[0], week[1], 1)


def normalize_domain(row: dict) -> str:
    domain = row.get("parent_category") or row.get("category") or ""
    return str(domain).strip().lower().replace(" ", "_")


def weekly_counts(rows: list[dict]) -> dict[str, dict[tuple[int, int], int]]:
    counts: dict[str, dict[tuple[int, int], int]] = defaultdict(lambda: defaultdict(int))
    for row in rows:
        domain = normalize_domain(row)
        if not domain:
            continue
        event_date = row_event_date(row)
        week = week_key(event_date.isoformat() if event_date else None)
        if not week:
            continue
        counts[domain][week] += 1
    return counts


def pair_key(domain_a: str, domain_b: str, connection_type: str) -> tuple[str, str, str]:
    left, right = sorted([domain_a.lower(), domain_b.lower()])
    return left, right, connection_type


def load_queue(queue_path: Path) -> list[dict]:
    if not queue_path.exists():
        return []
    return json.loads(queue_path.read_text())


def save_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def existing_queue_keys(queue: list[dict]) -> set[tuple[str, str, str]]:
    keys = set()
    for claim in queue:
        a = claim.get("domain_a")
        b = claim.get("domain_b")
        t = claim.get("connection_type")
        if a and b and t:
            keys.add(pair_key(str(a), str(b), str(t)))
    return keys


def accepted_pairs(accepted_graph: Path) -> dict[tuple[str, str], dict]:
    if not accepted_graph.exists():
        return {}
    text = accepted_graph.read_text()
    pairs: dict[tuple[str, str], dict] = {}
    for block in re.split(r"\n\s*\n", text):
        if 'understood:connectionType "observed_correlation"' not in block:
            continue
        domains = re.findall(r"understood:inLifeDomain <https://understood\.app/ontology/domain/([^>]+)>", block)
        if len(domains) < 2:
            continue
        strength_match = re.search(r'understood:strength "([0-9.]+)"', block)
        strength = float(strength_match.group(1)) if strength_match else None
        evidence_match = re.search(r'understood:evidenceNote "((?:[^"\\]|\\.)*)"', block)
        evidence_note = evidence_match.group(1) if evidence_match else ""
        left, right = sorted([domains[0].lower(), domains[1].lower()])
        pairs[(left, right)] = {
            "accepted_strength": strength,
            "evidence_note": evidence_note,
        }
    return pairs


def accepted_correlation_stats(
    counts: dict[str, dict[tuple[int, int], int]],
    domain_a: str,
    domain_b: str,
    tracked_weeks: list[tuple[int, int]],
) -> dict | None:
    if not tracked_weeks:
        return None
    series_a = [counts[domain_a].get(week, 0) for week in tracked_weeks]
    series_b = [counts[domain_b].get(week, 0) for week in tracked_weeks]
    median_a = statistics.median(series_a)
    median_b = statistics.median(series_b)
    active_a = [1 if value > median_a else 0 for value in series_a]
    active_b = [1 if value > median_b else 0 for value in series_b]
    mean_a = sum(active_a) / len(active_a)
    mean_b = sum(active_b) / len(active_b)
    deviation_a = [value - mean_a for value in active_a]
    deviation_b = [value - mean_b for value in active_b]
    variance_a = sum(value * value for value in deviation_a)
    variance_b = sum(value * value for value in deviation_b)
    if variance_a == 0 or variance_b == 0:
        return None
    correlation = sum(a * b for a, b in zip(deviation_a, deviation_b)) / math.sqrt(variance_a * variance_b)
    return {
        "domain_a": domain_a,
        "domain_b": domain_b,
        "active_weeks": len(tracked_weeks),
        "percent": correlation,
        "range_start": week_start(tracked_weeks[0]).isoformat(),
        "range_end": (week_start(tracked_weeks[-1]) + dt.timedelta(days=6)).isoformat(),
        "mean_a": mean_a,
        "mean_b": mean_b,
        "median_a": median_a,
        "median_b": median_b,
        "active_count_a": sum(active_a),
        "active_count_b": sum(active_b),
        "coactive_count": sum(1 for left, right in zip(active_a, active_b) if left and right),
        "method": ACCEPTED_CORRELATION_METRIC,
    }


def baseline_weeks_for_evidence(evidence_note: str, trusted_weeks: list[tuple[int, int]]) -> list[tuple[int, int]]:
    count_match = re.search(r"(\d+)\s+weeks", evidence_note)
    if count_match:
        count = int(count_match.group(1))
        if 0 < count <= len(trusted_weeks):
            return trusted_weeks[:count]

    range_match = re.search(r"(\d{4}-\d{2}-\d{2})\s+to\s+(\d{4}-\d{2}-\d{2})", evidence_note)
    if range_match:
        start = parse_date(range_match.group(1))
        end = parse_date(range_match.group(2))
        if start and end:
            return [
                week
                for week in trusted_weeks
                if start <= week_start(week)
                and (week_start(week) + dt.timedelta(days=6)) <= end
            ]

    return trusted_weeks


def plain_pair(domain_a: str, domain_b: str) -> str:
    return f"{domain_a.replace('_', ' ').title()} and {domain_b.replace('_', ' ').title()}"


def evidence_note(stats: dict) -> str:
    percent = round(stats["percent"] * 100)
    return (
        f"Robust correlation {percent}% across {stats['active_weeks']} tracked weeks "
        f"({stats['range_start']} to {stats['range_end']}). "
        "Metric: each category is yes/no for weeks above its own median, so logging-volume spikes do not dominate."
    )


def next_candidate_id(queue: list[dict], run_date: str, domain_a: str, domain_b: str, connection_type: str) -> str:
    slug = f"{domain_a}-{domain_b}-{connection_type}".replace("_", "-")
    return f"cand-supabase-{run_date}-{slug}"


def build_observed_claim(stats: dict, run_date: str) -> dict:
    domain_a = stats["domain_a"]
    domain_b = stats["domain_b"]
    label = f"{plain_pair(domain_a, domain_b)} move together across tracked weeks."
    return {
        "id": next_candidate_id([], run_date, domain_a, domain_b, OBSERVED),
        "status": "pending",
        "plain": label,
        "evidence": evidence_note(stats),
        "source": f"supabase-ingest {run_date}",
        "domain_a": domain_a,
        "domain_b": domain_b,
        "strength": round(stats["percent"], 2),
        "connection_type": OBSERVED,
    }


def build_weakening_claim(domain_a: str, domain_b: str, old_strength: float, stats: dict, run_date: str) -> dict:
    old_percent = round(old_strength * 100)
    new_percent = round(stats["percent"] * 100)
    plain = (
        f"This connection may be weakening: {plain_pair(domain_a, domain_b)} "
        f"correlation support was {old_percent}%, now {new_percent}%."
    )
    return {
        "id": next_candidate_id([], run_date, domain_a, domain_b, WEAKENING),
        "status": "pending",
        "plain": plain,
        "evidence": evidence_note(stats),
        "source": f"supabase-ingest {run_date}",
        "domain_a": domain_a,
        "domain_b": domain_b,
        "strength": round(stats["percent"], 2),
        "connection_type": WEAKENING,
    }


def append_ingest_log(log_path: Path, entry: dict) -> None:
    log = []
    if log_path.exists():
        log = json.loads(log_path.read_text())
    log.append(entry)
    save_json(log_path, log)


def run(
    ontology_root: Path,
    dry_run: bool = False,
    start_date: dt.date = DEFAULT_START_DATE,
    end_date: dt.date | None = None,
) -> dict:
    run_date = dt.date.today().isoformat()
    if end_date is None:
        end_date = dt.date.today()
    if start_date > end_date:
        raise SystemExit("Trusted date window start must be on or before the end date.")
    candidates_dir = ontology_root / "candidates"
    queue_path = candidates_dir / "queue.json"
    accepted_graph = ontology_root / "accepted" / "accepted-graph.ttl"
    refresh_report_path = candidates_dir / "refresh-report.json"
    ingest_log_path = candidates_dir / "ingest-log.json"

    rows = fetch_extractions()
    trusted_rows = filter_rows_by_date_window(rows, start_date, end_date)
    counts = weekly_counts(trusted_rows)
    trusted_weeks = sorted({week for weeks in counts.values() for week in weeks})
    domains = sorted(domain for domain, weeks in counts.items() if weeks)
    queue = load_queue(queue_path)
    queue_keys = existing_queue_keys(queue)
    run_source = f"supabase-ingest {run_date}"
    existing_run_claims = [claim for claim in queue if claim.get("source") == run_source]
    remaining_run_slots = max(0, MAX_NEW_CANDIDATES - len(existing_run_claims))
    accepted = accepted_pairs(accepted_graph)

    all_stats: dict[tuple[str, str], dict] = {}
    for index, domain_a in enumerate(domains):
        for domain_b in domains[index + 1 :]:
            stats = accepted_correlation_stats(counts, domain_a, domain_b, trusted_weeks)
            if stats:
                all_stats[(domain_a, domain_b)] = stats

    new_claims: list[dict] = []
    accepted_pair_set = set(accepted)
    for (domain_a, domain_b), stats in sorted(
        all_stats.items(),
        key=lambda item: (-item[1]["percent"], item[0][0], item[0][1]),
    ):
        if len(new_claims) >= remaining_run_slots:
            break
        if (domain_a, domain_b) in accepted_pair_set:
            continue
        if pair_key(domain_a, domain_b, OBSERVED) in queue_keys:
            continue
        if stats["percent"] >= 0.55 and stats["active_weeks"] >= 40:
            claim = build_observed_claim(stats, run_date)
            claim["id"] = next_candidate_id(queue + new_claims, run_date, domain_a, domain_b, OBSERVED)
            new_claims.append(claim)
            queue_keys.add(pair_key(domain_a, domain_b, OBSERVED))

    refresh_rows = []
    for (domain_a, domain_b), accepted_info in sorted(accepted.items()):
        baseline_weeks = baseline_weeks_for_evidence(
            str(accepted_info.get("evidence_note") or ""),
            trusted_weeks,
        )
        previous_stats = accepted_correlation_stats(counts, domain_a, domain_b, baseline_weeks)
        stats = all_stats.get((domain_a, domain_b))
        if not stats or not previous_stats:
            continue
        refresh_rows.append(
            {
                "domain_a": domain_a,
                "domain_b": domain_b,
                "accepted_graph_strength": accepted_info.get("accepted_strength"),
                "previous_strength": round(previous_stats["percent"], 4),
                "current_strength": round(stats["percent"], 4),
                "metric": ACCEPTED_CORRELATION_METRIC,
                "previous_active_weeks": previous_stats["active_weeks"],
                "previous_range_start": previous_stats["range_start"],
                "previous_range_end": previous_stats["range_end"],
                "current_active_weeks": stats["active_weeks"],
                "current_range_start": stats["range_start"],
                "current_range_end": stats["range_end"],
            }
        )
        if (
            len(new_claims) < remaining_run_slots
            and previous_stats["percent"] >= MIN_WEAKENING_BASELINE
            and stats["percent"] < MAX_WEAKENING_CURRENT
            and pair_key(domain_a, domain_b, WEAKENING) not in queue_keys
        ):
            new_claims.append(build_weakening_claim(domain_a, domain_b, previous_stats["percent"], stats, run_date))
            queue_keys.add(pair_key(domain_a, domain_b, WEAKENING))

    run_summary = {
        "date": dt.datetime.now(dt.timezone.utc).isoformat(),
        "extraction_count": len(rows),
        "trusted_extraction_count": len(trusted_rows),
        "trusted_start_date": start_date.isoformat(),
        "trusted_end_date": end_date.isoformat(),
        "trusted_week_count": len(trusted_weeks),
        "trusted_week_range": [
            week_start(trusted_weeks[0]).isoformat(),
            (week_start(trusted_weeks[-1]) + dt.timedelta(days=6)).isoformat(),
        ] if trusted_weeks else [],
        "category_count": len(domains),
        "candidates_created": len(new_claims),
        "dry_run": dry_run,
    }
    refresh_report = {
        "generated_at": run_summary["date"],
        "extraction_count": len(rows),
        "trusted_extraction_count": len(trusted_rows),
        "trusted_start_date": start_date.isoformat(),
        "trusted_end_date": end_date.isoformat(),
        "trusted_week_count": len(trusted_weeks),
        "trusted_week_range": [
            week_start(trusted_weeks[0]).isoformat(),
            (week_start(trusted_weeks[-1]) + dt.timedelta(days=6)).isoformat(),
        ] if trusted_weeks else [],
        "accepted_observed_correlation_count": len(refresh_rows),
        "connections": refresh_rows,
    }

    if not dry_run:
        if new_claims:
            queue.extend(new_claims)
            save_json(queue_path, queue)
        save_json(refresh_report_path, refresh_report)
        append_ingest_log(ingest_log_path, run_summary)

    return {
        **run_summary,
        "new_claims": new_claims,
        "refresh_report_path": str(refresh_report_path),
        "queue_path": str(queue_path),
    }


def main() -> int:
    load_local_env()
    parser = argparse.ArgumentParser(description="Ingest Supabase evidence into the review queue.")
    parser.add_argument("--ontology-root", type=Path, default=default_ontology_root())
    parser.add_argument("--start-date", type=parse_cli_date, default=DEFAULT_START_DATE)
    parser.add_argument("--end-date", type=parse_cli_date, default=dt.date.today())
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    result = run(
        args.ontology_root,
        dry_run=args.dry_run,
        start_date=args.start_date,
        end_date=args.end_date,
    )
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
