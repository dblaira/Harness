#!/usr/bin/env python3
"""Capture the exact installed Ollama model identity without mutating it."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path


def fetch_state(upstream: str) -> dict:
    request = urllib.request.Request(f"{upstream.rstrip('/')}/api/tags", method="GET")
    with urllib.request.urlopen(request, timeout=10) as response:
        payload = json.loads(response.read())
    models = []
    for item in payload.get("models", []):
        if not isinstance(item, dict):
            continue
        models.append(
            {
                "name": str(item.get("name") or item.get("model") or ""),
                "model": str(item.get("model") or item.get("name") or ""),
                "digest": str(item.get("digest") or ""),
            }
        )
    models.sort(key=lambda item: (item["name"], item["model"], item["digest"]))
    canonical = json.dumps(models, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return {"schema_version": 1, "sha256": hashlib.sha256(canonical).hexdigest(), "models": models}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--upstream", default="http://127.0.0.1:11434")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        state = fetch_state(args.upstream)
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
        print(f"could not snapshot Ollama state: {error}", file=sys.stderr)
        return 1
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
