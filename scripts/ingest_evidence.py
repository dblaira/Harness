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
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections import defaultdict
from pathlib import Path
from statistics import median

SUPABASE_PROJECT_URL = "https://wqdacfrzurhpsiuvzxwo.supabase.co"
MAX_NEW_CANDIDATES = 10
OBSERVED = "observed_correlation"
WEAKENING = "weakening_review"


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
    key = os.environ.get("SUPABASE_PUBLISHABLE_KEY", "")
    if not key:
        raise SystemExit("SUPABASE_PUBLISHABLE_KEY is missing from local .env.")
    bearer = (
        os.environ.get("SUPABASE_ACCESS_TOKEN")
        or os.environ.get("SUPABASE_JWT")
        or key
    )
    return {
        "apikey": key,
        "Authorization": f"Bearer {bearer}",
        "Accept": "application/json",
    }


def rest_get(path: str, query: dict[str, str], offset: int, limit: int) -> list[dict]:
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


def week_key(value: str | None) -> tuple[int, int] | None:
    parsed = parse_date(value)
    if not parsed:
        return None
    iso = parsed.isocalendar()
    return iso.year, iso.week


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
        week = week_key(row.get("time_window_start") or row.get("created_at"))
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


def accepted_pairs(accepted_graph: Path) -> dict[tuple[str, str], float | None]:
    if not accepted_graph.exists():
        return {}
    text = accepted_graph.read_text()
    pairs: dict[tuple[str, str], float | None] = {}
    for block in re.split(r"\n\s*\n", text):
        if 'understood:connectionType "observed_correlation"' not in block:
            continue
        domains = re.findall(r"understood:inLifeDomain <https://understood\.app/ontology/domain/([^>]+)>", block)
        if len(domains) < 2:
            continue
        strength_match = re.search(r'understood:strength "([0-9.]+)"', block)
        strength = float(strength_match.group(1)) if strength_match else None
        left, right = sorted([domains[0].lower(), domains[1].lower()])
        pairs[(left, right)] = strength
    return pairs


def co_rise_stats(
    counts: dict[str, dict[tuple[int, int], int]],
    domain_a: str,
    domain_b: str,
) -> dict | None:
    weeks_a = set(counts[domain_a])
    weeks_b = set(counts[domain_b])
    active_weeks = sorted(weeks_a | weeks_b)
    if not active_weeks:
        return None
    median_a = median(counts[domain_a].values())
    median_b = median(counts[domain_b].values())
    co_weeks = [
        week
        for week in active_weeks
        if counts[domain_a].get(week, 0) > median_a
        and counts[domain_b].get(week, 0) > median_b
    ]
    percent = len(co_weeks) / len(active_weeks)
    return {
        "domain_a": domain_a,
        "domain_b": domain_b,
        "co_weeks": len(co_weeks),
        "active_weeks": len(active_weeks),
        "percent": percent,
        "range_start": week_start(active_weeks[0]).isoformat(),
        "range_end": (week_start(active_weeks[-1]) + dt.timedelta(days=6)).isoformat(),
        "median_a": median_a,
        "median_b": median_b,
    }


def plain_pair(domain_a: str, domain_b: str) -> str:
    return f"{domain_a.replace('_', ' ').title()} and {domain_b.replace('_', ' ').title()}"


def evidence_note(stats: dict) -> str:
    percent = round(stats["percent"] * 100)
    return (
        f"Co-rose {percent}% across {stats['active_weeks']} active weeks "
        f"({stats['range_start']} to {stats['range_end']})."
    )


def next_candidate_id(queue: list[dict], run_date: str, domain_a: str, domain_b: str, connection_type: str) -> str:
    slug = f"{domain_a}-{domain_b}-{connection_type}".replace("_", "-")
    return f"cand-supabase-{run_date}-{slug}"


def build_observed_claim(stats: dict, run_date: str) -> dict:
    domain_a = stats["domain_a"]
    domain_b = stats["domain_b"]
    label = f"{plain_pair(domain_a, domain_b)} rise together in high-activity weeks."
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
        f"co-rise support was {old_percent}%, now {new_percent}%."
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


def run(ontology_root: Path, dry_run: bool = False) -> dict:
    run_date = dt.date.today().isoformat()
    candidates_dir = ontology_root / "candidates"
    queue_path = candidates_dir / "queue.json"
    accepted_graph = ontology_root / "accepted" / "accepted-graph.ttl"
    refresh_report_path = candidates_dir / "refresh-report.json"
    ingest_log_path = candidates_dir / "ingest-log.json"

    rows = fetch_extractions()
    counts = weekly_counts(rows)
    domains = sorted(domain for domain, weeks in counts.items() if weeks)
    queue = load_queue(queue_path)
    queue_keys = existing_queue_keys(queue)
    accepted = accepted_pairs(accepted_graph)

    all_stats: dict[tuple[str, str], dict] = {}
    for index, domain_a in enumerate(domains):
        for domain_b in domains[index + 1 :]:
            stats = co_rise_stats(counts, domain_a, domain_b)
            if stats:
                all_stats[(domain_a, domain_b)] = stats

    new_claims: list[dict] = []
    accepted_pair_set = set(accepted)
    for (domain_a, domain_b), stats in sorted(
        all_stats.items(),
        key=lambda item: (-item[1]["percent"], item[0][0], item[0][1]),
    ):
        if len(new_claims) >= MAX_NEW_CANDIDATES:
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
    for (domain_a, domain_b), old_strength in sorted(accepted.items()):
        stats = all_stats.get((domain_a, domain_b))
        if not stats:
            continue
        refresh_rows.append(
            {
                "domain_a": domain_a,
                "domain_b": domain_b,
                "previous_strength": old_strength,
                "current_strength": round(stats["percent"], 4),
                "active_weeks": stats["active_weeks"],
                "range_start": stats["range_start"],
                "range_end": stats["range_end"],
            }
        )
        if (
            len(new_claims) < MAX_NEW_CANDIDATES
            and stats["percent"] < 0.50
            and old_strength is not None
            and pair_key(domain_a, domain_b, WEAKENING) not in queue_keys
        ):
            new_claims.append(build_weakening_claim(domain_a, domain_b, old_strength, stats, run_date))
            queue_keys.add(pair_key(domain_a, domain_b, WEAKENING))

    run_summary = {
        "date": dt.datetime.now(dt.timezone.utc).isoformat(),
        "extraction_count": len(rows),
        "category_count": len(domains),
        "candidates_created": len(new_claims),
        "dry_run": dry_run,
    }
    refresh_report = {
        "generated_at": run_summary["date"],
        "extraction_count": len(rows),
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
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    result = run(args.ontology_root, dry_run=args.dry_run)
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
