#!/usr/bin/env python3
"""
Review Queue - plain-English claim approval for the Understood accepted graph.

Adam's one control surface. No RDF knowledge required.

What it does:
  1. Shows one claim at a time in plain English, with evidence.
  2. Adam types: y (accept) / n (reject) / s (skip).
  3. Accepted claims are written as W3C Turtle matching the existing
     understood: vocabulary (Connection, connectionType, inLifeDomain).
  4. Output validates with rdflib before anything is saved. Invalid = blocked.
  5. Every decision is logged to a ledger (JSON): who/what/when/why.

Usage:
  pip install rdflib
  python3 review_queue.py                 # review pending claims
  python3 review_queue.py --status        # counts only
  python3 review_queue.py --export        # print accepted graph Turtle

Files it creates (same folder, safe to sync to iCloud/Obsidian):
  queue.json            pending claims (seeded on first run)
  accepted-graph.ttl    the deterministic layer you own
  decision-ledger.json  every approve/reject with timestamp
"""

import argparse
import json
import subprocess
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

BASE = Path(__file__).parent
QUEUE_FILE = BASE / "queue.json"
GRAPH_FILE = BASE / "accepted-graph.ttl"
LEDGER_FILE = BASE / "decision-ledger.json"
VALIDATOR = BASE / "scripts" / "validate_connection_turtle.py"

PREFIXES = """@prefix understood: <https://understood.app/ontology#> .
@prefix xsd: <http://www.w3.org/2001/XMLSchema#> .

"""

# Seed claims: the 23 correlations from Cross-Domain Correlation Analysis
# (June 2024-March 2026, 92 weeks, 4,873 extractions).
# Each becomes a plain-English question Adam can answer.
SEED_CORRELATIONS = [
    ("Affect", "Learning", 67),
    ("Insight", "Purchase", 66),
    ("Learning", "Purchase", 66),
    ("Ambition", "Learning", 65),
    ("Affect", "Social", 63),
    ("Ambition", "Insight", 62),
    ("Insight", "Learning", 62),
    ("Learning", "Social", 61),
    ("Ambition", "Belief", 59),
    ("Social", "Work", 59),
    ("Exercise", "Sleep", 57),
    ("Affect", "Ambition", 56),
    ("Ambition", "Purchase", 56),
    ("Belief", "Insight", 55),
    ("Belief", "Work", 55),
    ("Health", "Learning", 55),
    ("Belief", "Learning", 55),
    ("Affect", "Insight", 54),
    ("Ambition", "Work", 53),
    ("Affect", "Work", 53),
    ("Affect", "Belief", 53),
    ("Affect", "Purchase", 51),
    ("Affect", "Entertainment", 51),
]


def seed_queue():
    claims = []
    for i, (a, b, pct) in enumerate(SEED_CORRELATIONS, start=1):
        claims.append(
            {
                "id": f"cand-{i:03d}",
                "status": "pending",
                "plain": f"{a} and {b} rise together in the same week.",
                "evidence": (
                    f"Co-rose {pct}% of tracked weeks "
                    "(92 weeks, Jun 2024-Mar 2026)."
                ),
                "source": "Cross-Domain Correlation Analysis, 2026-03-17",
                "domain_a": a.lower(),
                "domain_b": b.lower(),
                "strength": pct / 100.0,
                "connection_type": "observed_correlation",
            }
        )
    return claims


def load_queue():
    if not QUEUE_FILE.exists():
        claims = seed_queue()
        QUEUE_FILE.write_text(json.dumps(claims, indent=2))
        return claims
    return json.loads(QUEUE_FILE.read_text())


def save_queue(claims):
    QUEUE_FILE.write_text(json.dumps(claims, indent=2))


def load_ledger():
    if LEDGER_FILE.exists():
        return json.loads(LEDGER_FILE.read_text())
    return []


def append_ledger(entry):
    ledger = load_ledger()
    ledger.append(entry)
    LEDGER_FILE.write_text(json.dumps(ledger, indent=2))


def claim_to_turtle(claim, frequency="usually"):
    """Emit a Connection matching the existing adam-beliefs.ttl vocabulary."""
    cid = claim["id"].replace("cand-", "conn-obs-")
    uri = f"<https://understood.app/ontology/connection/{cid}>"
    domains = [
        claim.get("domain_a", "").strip(),
        claim.get("domain_b", "").strip(),
    ]
    domain_lines = "\n".join(
        f"  understood:inLifeDomain <https://understood.app/ontology/domain/{domain}> ;"
        for domain in domains
        if domain
    )
    label = claim["plain"].rstrip(".").replace('"', "'")
    accepted_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    strength_line = ""
    if claim.get("strength") is not None:
        strength_line = f'  understood:strength "{claim["strength"]:.2f}"^^xsd:decimal ;\n'
    return f"""{uri} a understood:Connection ;
  understood:label "{label}" ;
  understood:connectionType "{claim['connection_type']}" ;
{domain_lines + chr(10) if domain_lines else ""}\
{strength_line}\
  understood:frequency "{frequency}" ;
  understood:evidenceNote "{claim['evidence']}" ;
  understood:acceptedAt "{accepted_at}"^^xsd:dateTime ;
  .

"""


def validate_turtle(turtle_text):
    """Malformed or SHACL-invalid Turtle never reaches the accepted graph."""
    if not VALIDATOR.exists():
        return False, "SHACL validator script was not found."
    completed = subprocess.run(
        [sys.executable, str(VALIDATOR), "--json"],
        input=PREFIXES + turtle_text,
        text=True,
        capture_output=True,
        check=False,
    )
    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError:
        return False, completed.stderr.strip() or "SHACL validation failed."
    if completed.returncode == 0 and payload.get("conforms"):
        return True, "SHACL validation passed"
    messages = payload.get("messages") or ["claim does not match the accepted connection grammar"]
    return False, "; ".join(messages)


def append_to_graph(turtle_text):
    if not GRAPH_FILE.exists():
        header = (
            "# Accepted graph - claims approved by Adam via review queue.\n"
            "# Every entry passed rdflib validation before saving.\n\n"
        )
        GRAPH_FILE.write_text(header + PREFIXES)
    with GRAPH_FILE.open("a") as graph:
        graph.write(turtle_text)


def review(claims):
    pending = [claim for claim in claims if claim["status"] == "pending"]
    if not pending:
        print("Queue empty. Nothing to review.")
        return

    print(f"\n{len(pending)} claims waiting.\n" + "=" * 52)
    for claim in pending:
        print(f"\nCLAIM   {claim['plain']}")
        print(f"WHY     {claim['evidence']}")
        print(f"FROM    {claim['source']}")
        ans = input(
            "Accept? [y]es / [m] sometimes / [n]o / [s]kip / [q]uit > "
        ).strip().lower()

        if ans == "q":
            break
        if ans == "s" or ans == "":
            continue

        if ans == "y":
            decision, frequency = "accepted", "usually"
        elif ans == "m":
            decision, frequency = "accepted", "sometimes"
        else:
            decision, frequency = "rejected", None

        entry = {
            "ledger_id": str(uuid.uuid4())[:8],
            "claim_id": claim["id"],
            "decision": decision,
            "claim": claim["plain"],
            "at": datetime.now(timezone.utc).isoformat(),
        }

        if decision == "accepted":
            entry["frequency"] = frequency
            turtle = claim_to_turtle(claim, frequency)
            ok, detail = validate_turtle(turtle)
            if not ok:
                print(f"  BLOCKED - validation failed: {detail}")
                print("  Nothing was saved. Claim stays pending.")
                entry["decision"] = "blocked"
                entry["detail"] = detail
                append_ledger(entry)
                continue
            append_to_graph(turtle)
            print(f"  Accepted -> accepted-graph.ttl ({detail})")
        else:
            print("  Rejected. Logged.")

        claim["status"] = decision
        append_ledger(entry)
        save_queue(claims)

    done = sum(1 for claim in claims if claim["status"] != "pending")
    print(f"\nProgress: {done}/{len(claims)} decided. Graph: {GRAPH_FILE.name}")


def status(claims):
    counts = {}
    for claim in claims:
        counts[claim["status"]] = counts.get(claim["status"], 0) + 1
    for status_name, count in sorted(counts.items()):
        print(f"{status_name:>10}: {count}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--status", action="store_true")
    parser.add_argument("--export", action="store_true")
    args = parser.parse_args()

    claims = load_queue()
    if args.status:
        status(claims)
    elif args.export:
        print(GRAPH_FILE.read_text() if GRAPH_FILE.exists() else "(empty)")
    else:
        review(claims)


if __name__ == "__main__":
    main()
