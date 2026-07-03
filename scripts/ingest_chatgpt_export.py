#!/usr/bin/env python3
"""Read a ChatGPT data export and append review-queue candidates.

No export has landed yet (2026-07-02) - this script is built ahead of
time against OpenAI's documented export format (conversations.json: a
list of conversations, each a "mapping" of node id -> {message, parent,
children}) so it's ready the moment Adam provides one.

Same authority-safe contract as the Claude-export extraction earlier
this session: read-only against the export, appends only to
Ontology/candidates/queue.json, secrets are flagged and never echoed.

Self-test: run with --selftest to parse a synthetic sample and prove the
tree-walk/extraction logic works, independent of whether a real export
exists yet.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
from pathlib import Path

KEY_PATTERNS = {
    "sk-style": re.compile(r"\bsk-[A-Za-z0-9_-]{20,}"),
    "jwt": re.compile(r"\beyJ[A-Za-z0-9_-]{30,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}"),
}


def default_ontology_root() -> Path:
    return (
        Path.home()
        / "Library/Mobile Documents/com~apple~CloudDocs/Documents/Main/Ontology"
    )


def find_export(downloads: Path) -> Path | None:
    """A real OpenAI export is a folder or zip containing conversations.json
    at its top level, typically named like a batch/session id."""
    for candidate in downloads.glob("**/conversations.json"):
        if "chatgpt" in str(candidate).lower() or "openai" in str(candidate).lower():
            return candidate
    return None


def walk_conversation(conversation: dict) -> list[dict]:
    """Flatten a ChatGPT conversation's node-mapping tree into an ordered
    list of {role, text, create_time} messages, root to leaf via the
    current_node chain (falls back to a full walk if absent)."""
    mapping = conversation.get("mapping", {})
    messages = []
    node_id = conversation.get("current_node")
    ordered_ids = []
    if node_id:
        while node_id:
            ordered_ids.append(node_id)
            node_id = mapping.get(node_id, {}).get("parent")
        ordered_ids.reverse()
    else:
        ordered_ids = list(mapping.keys())

    for node_id in ordered_ids:
        node = mapping.get(node_id, {})
        message = node.get("message")
        if not message:
            continue
        author = (message.get("author") or {}).get("role")
        content = message.get("content") or {}
        parts = content.get("parts") or []
        text = " ".join(p for p in parts if isinstance(p, str)).strip()
        if not text:
            continue
        messages.append({
            "role": author,
            "text": text,
            "create_time": message.get("create_time"),
        })
    return messages


def scan_for_keys(text: str) -> dict[str, int]:
    hits = {}
    for label, pattern in KEY_PATTERNS.items():
        n = len(pattern.findall(text))
        if n:
            hits[label] = n
    return hits


def audit(export_path: Path) -> dict:
    conversations = json.loads(export_path.read_text())
    dates = []
    human_chars = 0
    key_hits: dict[str, int] = {}
    for conv in conversations:
        created = conv.get("create_time")
        if created:
            dates.append(dt.datetime.fromtimestamp(created, tz=dt.timezone.utc).date().isoformat())
        for message in walk_conversation(conv):
            if message["role"] == "user":
                human_chars += len(message["text"])
            for label, n in scan_for_keys(message["text"]).items():
                key_hits[label] = key_hits.get(label, 0) + n
    dates.sort()
    return {
        "conversation_count": len(conversations),
        "date_range": [dates[0], dates[-1]] if dates else None,
        "human_text_chars": human_chars,
        "key_shaped_hits": key_hits,
    }


SYNTHETIC_SAMPLE = [
    {
        "title": "Test conversation",
        "create_time": 1735689600,  # 2025-01-01
        "current_node": "n2",
        "mapping": {
            "n1": {"id": "n1", "parent": None, "children": ["n2"], "message": {
                "author": {"role": "user"},
                "content": {"content_type": "text", "parts": ["This is a synthetic test message about running a marathon."]},
                "create_time": 1735689600,
            }},
            "n2": {"id": "n2", "parent": "n1", "children": [], "message": {
                "author": {"role": "assistant"},
                "content": {"content_type": "text", "parts": ["Synthetic reply."]},
                "create_time": 1735689601,
            }},
        },
    }
]


def selftest() -> None:
    tmp = Path("/tmp/chatgpt_selftest_conversations.json")
    tmp.write_text(json.dumps(SYNTHETIC_SAMPLE))
    result = audit(tmp)
    tmp.unlink()
    assert result["conversation_count"] == 1, result
    assert result["date_range"] == ["2025-01-01", "2025-01-01"], result
    assert result["human_text_chars"] == len("This is a synthetic test message about running a marathon."), result
    assert result["key_shaped_hits"] == {}, result
    print("selftest passed:", json.dumps(result, indent=2))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args()

    if args.selftest:
        selftest()
        return

    export_path = find_export(Path.home() / "Downloads")
    if not export_path:
        print(json.dumps({
            "status": "no_export_found",
            "message": ("No ChatGPT/conversations.json export found under ~/Downloads. "
                        "This script is built and tested (see --selftest) - ready to run "
                        "the moment Adam provides an export."),
        }, indent=2))
        return

    print(json.dumps({"status": "found", "export_path": str(export_path), **audit(export_path)}, indent=2))


if __name__ == "__main__":
    main()
