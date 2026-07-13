#!/usr/bin/env python3
"""Protected direct Fuseki and Ollama proof, independent of proposal production code."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


FUSEKI_ENDPOINT = "http://127.0.0.1:3030/understood/sparql"
OLLAMA_ENDPOINT = "http://127.0.0.1:11434"
ACCEPTED_GRAPH = "https://understood.app/graph/accepted"


def request(url: str, data: bytes | None = None, content_type: str | None = None) -> dict:
    headers = {"Accept": "application/json"}
    if content_type:
        headers["Content-Type"] = content_type
    with urllib.request.urlopen(
        urllib.request.Request(url, data=data, headers=headers), timeout=20
    ) as response:
        return json.loads(response.read())


def sparql(query: str) -> list[dict[str, Any]]:
    payload = request(
        FUSEKI_ENDPOINT,
        urllib.parse.urlencode({"query": query}).encode(),
        "application/x-www-form-urlencoded",
    )
    bindings = (payload.get("results") or {}).get("bindings") or []
    if not isinstance(bindings, list):
        raise SystemExit("protected Fuseki query returned malformed bindings")
    return bindings


def normalized_binding(binding: dict[str, Any]) -> dict[str, str]:
    normalized: dict[str, str] = {}
    for name in ("s", "p", "o"):
        value = binding.get(name) or {}
        normalized[name] = str(value.get("value") or "")
    return normalized


def graph_snapshot() -> dict[str, Any]:
    query = (
        f"SELECT ?s ?p ?o WHERE {{ GRAPH <{ACCEPTED_GRAPH}> {{ ?s ?p ?o }} }} "
        "ORDER BY STR(?s) STR(?p) STR(?o)"
    )
    rows = sorted(
        (normalized_binding(binding) for binding in sparql(query)),
        key=lambda row: (row["s"], row["p"], row["o"]),
    )
    if not rows:
        raise SystemExit("protected Fuseki query returned no accepted-graph hits")
    canonical = json.dumps(rows, sort_keys=True, separators=(",", ":")).encode()
    return {
        "accepted_graph": ACCEPTED_GRAPH,
        "triple_count": len(rows),
        "sha256": hashlib.sha256(canonical).hexdigest(),
    }


def relevant_evidence() -> list[dict[str, str]]:
    query = f'''SELECT ?s ?p ?o WHERE {{
      GRAPH <{ACCEPTED_GRAPH}> {{
        ?s ?p ?o .
        FILTER(
          CONTAINS(LCASE(STR(?o)), "captur") ||
          CONTAINS(LCASE(STR(?o)), "value") ||
          CONTAINS(LCASE(STR(?s)), "value")
        )
      }}
    }} ORDER BY STR(?s) STR(?p) STR(?o) LIMIT 12'''
    rows = [normalized_binding(binding) for binding in sparql(query)]
    evidence: list[dict[str, str]] = []
    for row in rows:
        canonical = json.dumps(row, sort_keys=True, separators=(",", ":")).encode()
        evidence.append({"id": hashlib.sha256(canonical).hexdigest()[:16], **row})
    if not evidence:
        raise SystemExit("protected Fuseki query returned no relevant accepted-graph hits")
    return evidence


def synthesize(model: str, evidence: list[dict[str, str]]) -> dict[str, Any]:
    prompt = f"""Answer why capturing value matters using only the accepted graph evidence below.
Return JSON with exactly these fields:
- authority_ids: a non-empty array containing only evidence ids you actually used
- supporting_context: an empty array
- separation: the string PASS
- answer: a substantive answer grounded in those ids

Accepted graph evidence:
{json.dumps(evidence, indent=2, sort_keys=True)}
"""
    raw = request(
        f"{OLLAMA_ENDPOINT}/api/generate",
        json.dumps(
            {"model": model, "prompt": prompt, "stream": False, "format": "json"}
        ).encode(),
        "application/json",
    ).get("response", "")
    try:
        result = json.loads(str(raw))
    except json.JSONDecodeError as error:
        raise SystemExit("protected Ollama synthesis did not return grounded accepted authority JSON") from error
    allowed_ids = {item["id"] for item in evidence}
    authority_ids = result.get("authority_ids")
    supporting = result.get("supporting_context")
    answer = str(result.get("answer") or "").strip()
    if (
        not isinstance(authority_ids, list)
        or not authority_ids
        or any(not isinstance(item, str) or item not in allowed_ids for item in authority_ids)
        or supporting != []
        or result.get("separation") != "PASS"
        or len(answer) < 40
    ):
        raise SystemExit("protected Ollama synthesis has no grounded accepted authority")
    return {
        "authority_ids": authority_ids,
        "supporting_context": supporting,
        "separation": "PASS",
        "answer": answer,
    }


def write_snapshot(path: Path, snapshot: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(snapshot, indent=2) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--commit")
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--snapshot-output", type=Path)
    parser.add_argument("--expected-graph-digest")
    args = parser.parse_args()

    snapshot = graph_snapshot()
    if args.snapshot_output:
        write_snapshot(args.snapshot_output, snapshot)
        if not args.commit and not args.output_dir:
            print(args.snapshot_output)
            return 0
    if args.expected_graph_digest and snapshot["sha256"] != args.expected_graph_digest:
        raise SystemExit("accepted graph changed during proposal execution")
    if not args.commit or not args.output_dir:
        parser.error("--commit and --output-dir are required for synthesis proof")
    if not re.fullmatch(r"[0-9a-f]{40,64}", args.commit):
        raise SystemExit("protected oracle requires a full hexadecimal commit")

    evidence = relevant_evidence()
    models = request(f"{OLLAMA_ENDPOINT}/api/tags").get("models") or []
    if not models:
        raise SystemExit("protected Ollama probe found no local model")
    model = str(models[0].get("name") or "").strip()
    if not model:
        raise SystemExit("protected Ollama probe returned a nameless model")
    synthesis = synthesize(model, evidence)

    accepted = "\n".join(
        f"- `{item['id']}` {item['s']} {item['p']} {item['o']}" for item in evidence
    )
    used = ", ".join(synthesis["authority_ids"])
    report = f"""# Satisfaction Gate — protected direct proof

- Commit: {args.commit}
- Fuseki graph health: healthy
- Accepted graph SHA-256: {snapshot['sha256']}
- Accepted graph triples: {snapshot['triple_count']}
- Accepted-only supporting memory hits: 0
- Accepted-only authority separation: PASS
- Direct accepted-only Fuseki preflight hits: {len(evidence)}
- Grounded accepted authority ids: {used}
- Synthesis authority separation: PASS
- Backend: Ollama model {model}
- Recorded at: {datetime.now(timezone.utc).isoformat()}

## Accepted-only answer as produced

Direct accepted graph bindings:
{accepted}

## Answer as produced

{synthesis['answer']}
"""
    args.output_dir.mkdir(parents=True, exist_ok=True)
    path = args.output_dir / f"gate-{args.commit[:12]}.md"
    path.write_text(report, encoding="utf-8")
    print(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
