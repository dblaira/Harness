#!/usr/bin/env python3
"""Cross-process queue compare-and-swap through macOS NSFileCoordinator."""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
from pathlib import Path
from typing import Any


class ReviewQueueCoordinationError(RuntimeError):
    """The canonical review queue could not be safely coordinated."""


def ensure_queue_exists(queue_path: Path) -> None:
    queue_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        descriptor = os.open(queue_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        return
    with os.fdopen(descriptor, "wb") as handle:
        handle.write(b"[]\n")
        handle.flush()
        os.fsync(handle.fileno())


def decode_queue(data: bytes) -> list[dict[str, Any]]:
    try:
        value = json.loads(data)
    except json.JSONDecodeError as error:
        raise ReviewQueueCoordinationError("queue.json is not valid JSON") from error
    if not isinstance(value, list) or not all(isinstance(entry, dict) for entry in value):
        raise ReviewQueueCoordinationError("queue.json must be an array of objects")
    return value


def encode_queue(queue: list[dict[str, Any]]) -> bytes:
    return (json.dumps(queue, indent=2, sort_keys=True) + "\n").encode("utf-8")


def coordinated_compare_and_swap(
    queue_path: Path,
    expected: bytes,
    replacement: bytes,
    *,
    repository_root: Path,
) -> bool:
    helper = repository_root / "scripts/review_queue_compare_and_swap.swift"
    if not helper.is_file():
        raise ReviewQueueCoordinationError("review queue coordination helper was not found")

    expected_fd, expected_name = tempfile.mkstemp(prefix="queue-expected.", suffix=".json")
    replacement_fd, replacement_name = tempfile.mkstemp(
        prefix="queue-replacement.", suffix=".json"
    )
    try:
        with os.fdopen(expected_fd, "wb") as handle:
            handle.write(expected)
        with os.fdopen(replacement_fd, "wb") as handle:
            handle.write(replacement)
        try:
            completed = subprocess.run(
                [
                    "/usr/bin/xcrun",
                    "swift",
                    str(helper),
                    str(queue_path),
                    expected_name,
                    replacement_name,
                ],
                capture_output=True,
                text=True,
                check=False,
            )
        except OSError as error:
            raise ReviewQueueCoordinationError(
                f"review queue coordinator could not start: {error}"
            ) from error
    finally:
        for name in (expected_name, replacement_name):
            try:
                os.unlink(name)
            except FileNotFoundError:
                pass

    if completed.returncode == 0:
        return True
    if completed.returncode == 2:
        return False
    detail = completed.stderr.strip() or completed.stdout.strip()
    raise ReviewQueueCoordinationError(detail or "review queue coordination failed")


def append_queue_entries(
    queue_path: Path,
    entries: list[dict[str, Any]],
    *,
    repository_root: Path,
    max_attempts: int = 3,
) -> list[dict[str, Any]]:
    """Append without replacing rows written by another Harness process."""

    if not entries:
        return []
    ensure_queue_exists(queue_path)
    for _ in range(max(1, max_attempts)):
        expected = queue_path.read_bytes()
        queue = decode_queue(expected)
        existing = {entry.get("id"): entry for entry in queue if isinstance(entry.get("id"), str)}
        additions: list[dict[str, Any]] = []
        for entry in entries:
            entry_id = entry.get("id")
            if not isinstance(entry_id, str) or not entry_id:
                raise ReviewQueueCoordinationError("queue entry id must be non-empty text")
            present = existing.get(entry_id)
            if present is not None:
                if present != entry:
                    raise ReviewQueueCoordinationError(
                        f"queue entry id already exists with different content: {entry_id}"
                    )
                continue
            additions.append(entry)
            existing[entry_id] = entry
        if not additions:
            return []
        replacement = encode_queue([*queue, *additions])
        if coordinated_compare_and_swap(
            queue_path,
            expected,
            replacement,
            repository_root=repository_root,
        ):
            return additions
    raise ReviewQueueCoordinationError(
        "queue kept changing during coordinated append; nothing was overwritten"
    )
