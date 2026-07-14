#!/usr/bin/env python3
"""Create a deterministic snapshot of Adam's local accepted and candidate authority."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


def directory_digest(path: Path) -> tuple[str, int]:
    digest = hashlib.sha256()
    count = 0
    if not path.exists():
        digest.update(b"MISSING")
        return digest.hexdigest(), count
    for child in sorted(item for item in path.rglob("*") if item.is_file()):
        relative = str(child.relative_to(path))
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(child.read_bytes())
        digest.update(b"\0")
        count += 1
    return digest.hexdigest(), count


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ontology-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = args.ontology_root.expanduser().resolve()
    payload: dict[str, object] = {"schema_version": 1, "ontology_root": str(root)}
    for name in ("accepted", "candidates"):
        digest, count = directory_digest(root / name)
        payload[name] = {"sha256": digest, "file_count": count}
    queue = root / "candidates" / "queue.json"
    payload["queue"] = {
        "sha256": hashlib.sha256(queue.read_bytes()).hexdigest() if queue.is_file() else None,
        "exists": queue.is_file(),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
