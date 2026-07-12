#!/usr/bin/env python3
"""Prove Codex is using ChatGPT subscription authorization without an API key."""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path


API_ENVIRONMENT = (
    "OPENAI_API_KEY",
    "OPENAI_BASE_URL",
    "OPENAI_API_BASE",
    "AZURE_OPENAI_API_KEY",
    "ANTHROPIC_API_KEY",
    "GEMINI_API_KEY",
    "GOOGLE_API_KEY",
    "GROQ_API_KEY",
    "MISTRAL_API_KEY",
    "TOGETHER_API_KEY",
    "DEEPSEEK_API_KEY",
    "XAI_API_KEY",
)


def validate(auth: dict, environment: dict[str, str]) -> list[str]:
    errors = [f"{name} must be absent" for name in API_ENVIRONMENT if environment.get(name)]
    if auth.get("auth_mode") != "chatgpt":
        errors.append("Codex auth_mode is not chatgpt")
    if auth.get("OPENAI_API_KEY") not in (None, ""):
        errors.append("Codex auth file contains an API key")
    tokens = auth.get("tokens")
    if not isinstance(tokens, dict) or not tokens.get("access_token") or not tokens.get("account_id"):
        errors.append("Codex auth file lacks ChatGPT account tokens")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--auth-file", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        auth = json.loads(args.auth_file.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"cannot read Codex authorization: {error}", file=sys.stderr)
        return 1
    errors = validate(auth, dict(os.environ))
    proof = {
        "authorization_mode": "chatgpt_subscription" if not errors else "invalid",
        "api_key_present": bool(auth.get("OPENAI_API_KEY")) or any(os.environ.get(name) for name in API_ENVIRONMENT),
        "account_id_present": bool((auth.get("tokens") or {}).get("account_id")),
        "errors": errors,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(proof, indent=2) + "\n", encoding="utf-8")
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1
    print("Codex authorization is ChatGPT subscription mode with no API key.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
