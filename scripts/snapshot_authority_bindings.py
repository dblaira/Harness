#!/usr/bin/env python3
"""Snapshot every accepted-graph binding from the protected live endpoint."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


QUERY = """SELECT ?s ?p ?o WHERE {
  GRAPH <https://understood.app/graph/accepted> { ?s ?p ?o }
} ORDER BY ?s ?p ?o"""


def binding_key(subject: str, predicate: str, object_value: str) -> str:
    return "\u001f".join((subject, predicate, object_value))


def fetch_bindings(endpoint: str) -> dict:
    body = urllib.parse.urlencode({"query": QUERY}).encode("utf-8")
    request = urllib.request.Request(endpoint, data=body, method="POST")
    request.add_header("Content-Type", "application/x-www-form-urlencoded")
    request.add_header("Accept", "application/sparql-results+json")
    with urllib.request.urlopen(request, timeout=30) as response:
        payload = json.loads(response.read())
    triples = []
    for item in payload.get("results", {}).get("bindings", []):
        values = [str((item.get(name) or {}).get("value") or "") for name in ("s", "p", "o")]
        if not all(values):
            continue
        key = binding_key(*values)
        triples.append(
            {
                "subject": values[0],
                "predicate": values[1],
                "object": values[2],
                "sha256": hashlib.sha256(key.encode("utf-8")).hexdigest(),
            }
        )
    triples.sort(key=lambda item: (item["subject"], item["predicate"], item["object"]))
    canonical = json.dumps(triples, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return {
        "schema_version": 1,
        "accepted_graph": "https://understood.app/graph/accepted",
        "sha256": hashlib.sha256(canonical).hexdigest(),
        "triples": triples,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--endpoint", default="http://127.0.0.1:3030/understood/query")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        snapshot = fetch_bindings(args.endpoint)
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
        print(f"could not snapshot accepted authority bindings: {error}", file=sys.stderr)
        return 1
    if not snapshot["triples"]:
        print("accepted authority binding snapshot is empty", file=sys.stderr)
        return 1
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(snapshot, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
