#!/usr/bin/env python3
"""Prove the deployed News Calm DELETE route exists without deleting real data."""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


def project_value(project: str, key: str) -> str:
    match = re.search(rf'^\s*{re.escape(key)}:\s*"([^"]+)"\s*$', project, flags=re.MULTILINE)
    if not match:
        raise ValueError(f"{key} is missing from the app project")
    return match.group(1)


def probe(project_path: Path, timeout: float = 15) -> tuple[int, str]:
    project = project_path.read_text(encoding="utf-8")
    base_url = project_value(project, "BoringAPIBaseURL").rstrip("/")
    api_key = project_value(project, "BoringAPIKey")
    invalid_id = urllib.parse.quote("regression-route-probe", safe="")
    request = urllib.request.Request(
        f"{base_url}/articles/{invalid_id}",
        method="DELETE",
        headers={
            "Authorization": f"Bearer {api_key}",
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, response.read(4096).decode("utf-8", errors="replace")
    except urllib.error.HTTPError as error:
        return error.code, error.read(4096).decode("utf-8", errors="replace")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, required=True)
    args = parser.parse_args()
    try:
        status, body = probe(args.project)
    except Exception as error:
        print(f"FAIL: News Calm DELETE route probe could not run: {error}", file=sys.stderr)
        return 1
    if status != 400:
        print(f"FAIL: deployed DELETE /articles route returned HTTP {status}; expected safe validation HTTP 400", file=sys.stderr)
        return 1
    try:
        payload = json.loads(body)
    except json.JSONDecodeError:
        print("FAIL: deployed DELETE route did not return its JSON validation receipt", file=sys.stderr)
        return 1
    if not isinstance(payload, dict) or "error" not in payload:
        print("FAIL: deployed DELETE route returned HTTP 400 without an error receipt", file=sys.stderr)
        return 1
    print("PASS: deployed DELETE /articles route returned its safe HTTP 400 validation receipt")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
