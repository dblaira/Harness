#!/usr/bin/env python3
"""Render structured local Sol review evidence as a GitHub PR comment."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def clean(value: object) -> str:
    return str(value or "").replace("\r", " ").strip()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--review", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", required=True)
    parser.add_argument("--state", choices=("success", "failure"), required=True)
    args = parser.parse_args()
    try:
        review = json.loads(args.review.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        review = {}

    lines = [
        "## Independent GPT-5.6 Sol review",
        "",
        "This review ran locally on Adam's Mac through the existing ChatGPT/Codex subscription authorization. "
        "It used a read-only inert base/head bundle; Adam's Mac was not a GitHub Actions runner.",
        "",
        f"- Result: **{args.state.upper()}**",
        "- Model: `gpt-5.6-sol`",
        "- Reasoning: `max`",
        "- Sandbox: `read-only`",
        f"- Base: `{args.base}`",
        f"- Head: `{args.head}`",
        f"- Summary: {clean(review.get('summary')) or 'Structured review output was unavailable.'}",
        "",
        "### Findings",
        "",
    ]
    findings = review.get("findings") if isinstance(review, dict) else None
    if not isinstance(findings, list) or not findings:
        lines.append("No findings were returned.")
    else:
        for finding in findings:
            if not isinstance(finding, dict):
                continue
            severity = clean(finding.get("severity"))
            title = clean(finding.get("title"))
            location = clean(finding.get("file"))
            line = finding.get("line")
            if line:
                location = f"{location}:{line}"
            lines.extend(
                [
                    f"- **[{severity}] {title}** — `{location}`",
                    f"  {clean(finding.get('body'))}",
                    f"  Required proof: {clean(finding.get('required_proof'))}",
                ]
            )
    args.output.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
