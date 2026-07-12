#!/usr/bin/env python3
"""Shared neutral ``suite_capture.v1`` file output for legacy readers."""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import tempfile
from pathlib import Path
from typing import Any


def utc_timestamp(value: str | None = None, *, now: dt.datetime | None = None) -> str:
    if value:
        try:
            parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
            if parsed.tzinfo is None:
                parsed = parsed.replace(tzinfo=dt.timezone.utc)
            return parsed.astimezone(dt.timezone.utc).isoformat().replace("+00:00", "Z")
        except ValueError:
            pass
    observed = now or dt.datetime.now(dt.timezone.utc)
    if observed.tzinfo is None:
        observed = observed.replace(tzinfo=dt.timezone.utc)
    return observed.astimezone(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def canonical_json(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def build_suite_capture(
    *,
    source_slug: str,
    source_app: str,
    source_record_id: str,
    captured_at: str,
    capture_kind: str,
    payload: dict[str, Any],
    artifact_refs: list[str] | None = None,
) -> dict[str, Any]:
    refs = list(artifact_refs or [])
    identity = {
        "schema_version": "suite_capture.v1",
        "source_app": source_app,
        "source_record_id": source_record_id,
        "captured_at": captured_at,
        "capture_kind": capture_kind,
        "payload": payload,
        "artifact_refs": refs,
    }
    digest = hashlib.sha256(canonical_json(identity)).hexdigest()
    return {
        **identity,
        "capture_id": f"capture-{source_slug}-{digest[:32]}",
    }


def write_suite_capture(
    capture: dict[str, Any],
    inbox: Path,
    *,
    dry_run: bool = False,
) -> dict[str, str]:
    capture_id = capture.get("capture_id")
    if not isinstance(capture_id, str) or not capture_id.startswith("capture-"):
        raise ValueError("capture_id must be safe capture text")
    encoded = (
        json.dumps(capture, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    ).encode("utf-8")
    destination = inbox / f"{capture_id}.json"
    if dry_run:
        return {
            "status": "dry_run",
            "capture_id": capture_id,
            "capture_path": str(destination),
            "raw_sha256": hashlib.sha256(encoded).hexdigest(),
        }

    inbox.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        if destination.read_bytes() != encoded:
            raise ValueError(f"capture id already exists with different bytes: {capture_id}")
        return {
            "status": "already_present",
            "capture_id": capture_id,
            "capture_path": str(destination),
            "raw_sha256": hashlib.sha256(encoded).hexdigest(),
        }

    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{capture_id}.", suffix=".tmp", dir=inbox
    )
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        try:
            os.link(temporary_name, destination)
            status = "delivered"
        except FileExistsError:
            if destination.read_bytes() != encoded:
                raise ValueError(
                    f"capture id was concurrently written with different bytes: {capture_id}"
                )
            status = "already_present"
    finally:
        if os.path.exists(temporary_name):
            os.unlink(temporary_name)

    return {
        "status": status,
        "capture_id": capture_id,
        "capture_path": str(destination),
        "raw_sha256": hashlib.sha256(encoded).hexdigest(),
    }
